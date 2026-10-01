// SPDX-License-Identifier: MIT
//! The operator's confirmation, between the review and the signature.
//!
//! Every signing command prints its review to stderr first, then calls [`confirm`]. On a
//! terminal the operator must type `yes` (or `y`); anything else, including end of input,
//! refuses with exit code 3 and nothing is signed. When stdin is not a terminal keysmith
//! cannot ask, so it refuses unless `--yes` was passed: a script that forgot the flag never
//! signs unattended by accident.

use crate::error::CliError;
use std::io::{BufRead, IsTerminal, Write};

/// Asks for confirmation unless `yes` is set (see the module documentation).
pub fn confirm(yes: bool) -> Result<(), CliError> {
    if yes {
        return Ok(());
    }
    let stdin = std::io::stdin();
    if !stdin.is_terminal() {
        return Err(CliError::Input(
            "confirmation required, but stdin is not a terminal so keysmith cannot ask: review the \
             output above and re-run with --yes to sign non-interactively"
                .into(),
        ));
    }
    eprint!("Sign this? Type \"yes\" to confirm: ");
    let _ = std::io::stderr().flush();
    answer(&mut stdin.lock())
}

/// Reads one answer line: `yes` / `y` (any case) confirms, everything else refuses.
pub fn answer(reader: &mut dyn BufRead) -> Result<(), CliError> {
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .map_err(|e| CliError::Input(format!("cannot read the confirmation: {e}")))?;
    match line.trim().to_ascii_lowercase().as_str() {
        "y" | "yes" => Ok(()),
        _ => Err(CliError::Refused(
            "not confirmed by the operator; nothing was signed".into(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::EXIT_REFUSED;

    fn reply(text: &str) -> Result<(), CliError> {
        answer(&mut std::io::Cursor::new(text.as_bytes().to_vec()))
    }

    #[test]
    fn only_an_explicit_yes_confirms() {
        for ok in ["yes\n", "y\n", "YES\r\n", "  Yes  \n", "y"] {
            assert!(reply(ok).is_ok(), "{ok:?}");
        }
        for no in ["no\n", "n\n", "\n", "", "yess\n", "ye\n", "sure\n"] {
            let err = reply(no).unwrap_err();
            assert_eq!(err.exit_code(), EXIT_REFUSED, "{no:?}");
            assert!(err.to_string().contains("nothing was signed"));
        }
        assert!(confirm(true).is_ok(), "--yes skips the prompt");
    }
}
