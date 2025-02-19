use std::path::Path;
use std::{env, io};

use anyhow::{Context, Result};
use bpaf::{Bpaf, Parser};
use flox_rust_sdk::flox::Flox;
use flox_rust_sdk::nix::command_line::{Group, NixCliCommand, NixCommandLine, ToArgs};
use flox_rust_sdk::nix::Run;
use flox_rust_sdk::prelude::Channel;
use flox_types::stability::Stability;
use fslock::LockFile;
use indoc::indoc;
use log::info;
use serde::Serialize;
use tokio::fs;
use toml_edit::Key;

use crate::commands::not_help;
use crate::config::{Config, ReadWriteError, FLOX_CONFIG_FILE};
use crate::utils::metrics::{
    METRICS_EVENTS_FILE_NAME,
    METRICS_LOCK_FILE_NAME,
    METRICS_UUID_FILE_NAME,
};
use crate::{flox_forward, subcommand_metric};

/// reset the metrics queue (if any), reset metrics ID, and re-prompt for consent
#[derive(Bpaf, Clone)]
pub struct ResetMetrics {}
impl ResetMetrics {
    pub async fn handle(self, _config: Config, flox: Flox) -> Result<()> {
        subcommand_metric!("reset-metrics");
        let mut metrics_lock = LockFile::open(&flox.cache_dir.join(METRICS_LOCK_FILE_NAME))?;
        tokio::task::spawn_blocking(move || metrics_lock.lock()).await??;

        if let Err(err) =
            tokio::fs::remove_file(flox.cache_dir.join(METRICS_EVENTS_FILE_NAME)).await
        {
            match err.kind() {
                std::io::ErrorKind::NotFound => {},
                _ => Err(err)?,
            }
        }

        if let Err(err) = tokio::fs::remove_file(flox.data_dir.join(METRICS_UUID_FILE_NAME)).await {
            match err.kind() {
                std::io::ErrorKind::NotFound => {},
                _ => Err(err)?,
            }
        }

        let notice = indoc! {"
                    Sucessfully reset telemetry ID for this machine!

                    A new ID will be assigned next time you use flox.

                    The collection of metrics can be disabled in the following ways:

                      environment: FLOX_DISABLE_METRICS=true
                        user-wide: flox config --set-bool disable_metrics true
                      system-wide: update /etc/flox.toml as described in flox(1)
                "};

        info!("{notice}");
        Ok(())
    }
}

#[derive(Bpaf, Clone)]
#[bpaf(fallback(ConfigArgs::List))]
pub enum ConfigArgs {
    /// List the current values of all configurable parameters
    #[bpaf(short, long)]
    List,
    /// Reset all configurable parameters to their default values without further confirmation.
    #[bpaf(short, long)]
    Reset,
    /// Set a config value
    Set(#[bpaf(external(config_set))] ConfigSet),
    /// Set a numeric config value
    SetNumber(#[bpaf(external(config_set_number))] ConfigSetNumber),
    /// Set a boolean config value
    SetBool(#[bpaf(external(config_set_bool))] ConfigSetBool),
    /// Delete a config value
    Delete(#[bpaf(external(config_delete))] ConfigDelete),
}

impl ConfigArgs {
    /// handle config flags like commands
    pub async fn handle(&self, config: Config, flox: Flox) -> Result<()> {
        subcommand_metric!("config");

        /// wrapper around [Config::write_to]
        async fn update_config<V: Serialize>(
            config_dir: &Path,
            temp_dir: &Path,
            key: impl AsRef<str>,
            value: Option<V>,
        ) -> Result<()> {
            let query = Key::parse(key.as_ref()).context("Could not parse key")?;

            let config_file_path = config_dir.join(FLOX_CONFIG_FILE);

            match Config::write_to_in(config_file_path, temp_dir, &query, value) {
                err @ Err(ReadWriteError::ReadConfig(_)) => err.context("Could not read current config file.\nPlease verify the format or reset using `flox config --reset`")?,
                err @ Err(_) => err?,
                Ok(()) => ()
            }
            Ok(())
        }

        match self {
            ConfigArgs::List => println!("{}", config.get(&[])?),
            ConfigArgs::Reset => {
                match fs::remove_file(&flox.config_dir.join(FLOX_CONFIG_FILE)).await {
                    Err(err) if err.kind() != io::ErrorKind::NotFound => {
                        Err(err).context("Could not reset config file")?
                    },
                    _ => (),
                }
            },
            ConfigArgs::Set(ConfigSet { key, value, .. }) => {
                update_config(&flox.config_dir, &flox.temp_dir, key, Some(value)).await?
            },
            ConfigArgs::SetNumber(ConfigSetNumber { key, value, .. }) => {
                update_config(&flox.config_dir, &flox.temp_dir, key, Some(value)).await?
            },
            ConfigArgs::SetBool(ConfigSetBool { key, value, .. }) => {
                update_config(&flox.config_dir, &flox.temp_dir, key, Some(value)).await?
            },
            ConfigArgs::Delete(ConfigDelete { key, .. }) => {
                update_config::<()>(&flox.config_dir, &flox.temp_dir, key, None).await?
            },
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Bpaf)]
#[bpaf(adjacent)]
#[allow(unused)]
pub struct ConfigSet {
    /// set <key> to <value>
    set: (),
    /// Configuration key
    #[bpaf(positional("key"))]
    key: String,
    /// configuration Value
    #[bpaf(positional("value"))]
    value: String,
}

#[derive(Debug, Clone, Bpaf)]
#[bpaf(adjacent)]
#[allow(unused)]
pub struct ConfigSetNumber {
    /// Set <key> to <number>
    #[bpaf(long("set-number"))]
    set_number: (),
    /// Configuration key
    #[bpaf(positional("key"))]
    key: String,
    /// Configuration Value (i32)
    #[bpaf(positional("number"))]
    value: i32,
}

#[derive(Debug, Clone, Bpaf)]
#[bpaf(adjacent)]
#[allow(unused)]
pub struct ConfigSetBool {
    /// Set <key> to <bool>
    #[bpaf(long("set-bool"))]
    set_bool: (),
    /// Configuration key
    #[bpaf(positional("key"))]
    key: String,
    /// Configuration Value (bool)
    #[bpaf(positional("bool"))]
    value: bool,
}

#[derive(Debug, Clone, Bpaf)]
#[allow(unused)]
pub struct ConfigDelete {
    /// Configuration key
    #[bpaf(long("delete"), argument("key"))]
    key: String,
}

/// Access to the nix CLI
#[derive(Clone, Debug)]
pub struct WrappedNix {
    stability: Option<Stability>,
    nix_args: Vec<String>,
}

impl WrappedNix {
    pub async fn handle(self, mut config: Config, mut flox: Flox) -> Result<()> {
        subcommand_metric!("nix");
        // mutable state hurray :/
        let stability = config.override_stability(self.stability);

        if let Some(stability) = stability {
            flox.channels
                .register_channel("nixpkgs", Channel::from(stability.as_flakeref()));
        }

        let nix: NixCommandLine = flox.nix(Default::default());

        RawCommand::new(self.nix_args.to_owned())
            .run(&nix, &Default::default())
            .await?;
        Ok(())
    }
}

/// Access to the gh CLI
#[derive(Clone, Debug, Bpaf)]
pub struct Gh {
    #[bpaf(any("gh arguments and options", not_help))]
    _gh_args: Vec<String>,
}
impl Gh {
    pub async fn handle(self, _config: Config, flox: Flox) -> Result<()> {
        subcommand_metric!("gh");
        flox_forward(&flox).await
    }
}

/// floxHub authentication commands
#[derive(Clone, Debug, Bpaf)]
pub enum Auth {
    /// Login to floxhub
    #[bpaf(command)]
    Login(#[bpaf(any("gh option", not_help), help("gh auth login options"))] Vec<String>),
    /// Logout of floxhub
    #[bpaf(command)]
    Logout(#[bpaf(any("gh option", not_help), help("gh auth logout options"))] Vec<String>),
    /// Print login information
    #[bpaf(command)]
    Status(#[bpaf(any("gh option", not_help), help("gh auth status options"))] Vec<String>),
}

impl Auth {
    pub async fn handle(self, _config: Config, flox: Flox) -> Result<()> {
        subcommand_metric!("auth");
        flox_forward(&flox).await
    }
}

pub fn parse_nix_passthru() -> impl Parser<WrappedNix> {
    fn nix_sub_command<const OFFSET: u8>() -> impl Parser<Vec<String>> {
        let free = bpaf::any("NIX ARGUMENTS", not_help)
            .complete_shell(complete_nix_shell(OFFSET))
            .many();

        let strict = bpaf::positional("NIX ARGUMENTS AND OPTIONS")
            .strict()
            .many();

        bpaf::construct!(free, strict).map(|(free, strict)| [free, strict].concat())
    }

    let with_stability = {
        let stability = bpaf::long("stability").argument("STABILITY").map(Some);
        let nix_args = nix_sub_command::<2>();
        bpaf::construct!(WrappedNix {
            stability,
            nix_args
        })
        .adjacent()
    };

    let without_stability = {
        let stability = bpaf::pure(Default::default());
        let nix_args = nix_sub_command::<0>().hide();
        bpaf::construct!(WrappedNix {
            nix_args,
            stability
        })
        .hide()
    };

    bpaf::construct!([without_stability, with_stability])
}

fn complete_nix_shell(offset: u8) -> bpaf::ShellComp {
    // Box::leak will effectively turn the String
    // (that is produced by `replace`) insto a `&'static str`,
    // at the cost of giving up memory management over that string.
    //
    // Note:
    // We could use a `OnceCell` to ensure this leak happens only once.
    // However, this should not be necessary after all,
    // since the completion runs in its own process.
    // Any memory it leaks will be cleared by the system allocator.
    bpaf::ShellComp::Raw {
        zsh: Box::leak(
            format!(
                "OFFSET={}; echo 'was' > /dev/stderr; source {}",
                offset,
                env!("NIX_ZSH_COMPLETION_SCRIPT")
            )
            .into_boxed_str(),
        ),
        bash: Box::leak(
            format!(
                "OFFSET={}; source {}; _nix_bash_completion",
                offset,
                env!("NIX_BASH_COMPLETION_SCRIPT")
            )
            .into_boxed_str(),
        ),
        fish: "",
        elvish: "",
    }
}

/// A raw nix command.
///
/// Will run `nix <default args> <self.args>...`
///
/// Doesn't permit the application of any default arguments set by flox,
/// except nix configuration args and common nix command args.
///
/// See: [`nix --help`](https://nixos.org/manual/nix/unstable/command-ref/new-cli/nix.html)
#[derive(Debug, Clone)]
pub struct RawCommand {
    args: Vec<String>,
}

impl RawCommand {
    fn new(args: Vec<String>) -> Self {
        RawCommand { args }
    }
}
impl ToArgs for RawCommand {
    fn to_args(&self) -> Vec<String> {
        self.args.to_owned()
    }
}

impl NixCliCommand for RawCommand {
    type Own = Self;

    const OWN_ARGS: Group<Self, Self::Own> = Some(|s| s.to_owned());
    const SUBCOMMAND: &'static [&'static str] = &[];
}
