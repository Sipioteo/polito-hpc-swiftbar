# Security

## Cosa è in scope

Lo script `PoliTO_VPN.5s.sh` esegue `openfortivpn` con privilegi `root` via `sudo`. La configurazione di sudoers generata da `install.sh` è ristretta:

- `openfortivpn` solo verso l'host specificato in fase di install, con `--saml-login`
- `pkill -x openfortivpn` e `pkill -x pppd` (con e senza `-9`), nient'altro

Non viene mai concesso `NOPASSWD: ALL`. Se trovi una configurazione più ampia leggendo `install.sh`, è un bug e va segnalato.

## Come segnalare

Apri una issue su GitHub con tag `security` se la vulnerabilità è già pubblica. Per problemi che vuoi divulgare in modo coordinato, usa la funzione "Report a vulnerability" su GitHub Security Advisories.

## Cosa NON è in scope

- Sicurezza del cluster HPC remoto (gestita dagli admin PoliTO)
- Sicurezza di `openfortivpn`, `tmux`, `SwiftBar`, Homebrew (upstream)
- Configurazione SSH dell'utente (`~/.ssh/config`, chiavi private)
