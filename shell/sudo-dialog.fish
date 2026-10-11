# sudo-dialog shell integration for fish, sourced from config.fish by
# `sudo-dialog install`, which also sets SUDO_DIALOG_HOME. Same behaviour as
# shell/sudo-dialog.sh: export SUDO_ASKPASS, and add -A when there is no
# terminal.

if set -q SUDO_DIALOG_HOME; and test -x "$SUDO_DIALOG_HOME/libexec/sudo-dialog-askpass"
    set -gx SUDO_ASKPASS "$SUDO_DIALOG_HOME/libexec/sudo-dialog-askpass"

    function sudo --wraps sudo --description 'sudo, with a password dialog when there is no terminal'
        # A terminal is available: sudo asks there, as usual.
        if sh -c ': </dev/tty' 2>/dev/null
            command sudo $argv
            return
        end
        # Leave callers alone that chose how sudo gets the password, or chose
        # that it must not ask: -S/--stdin, -A/--askpass, -n/--non-interactive.
        set -l skip 0
        for arg in $argv
            if test $skip = 1
                set skip 0
                continue
            end
            switch $arg
                case --
                    break
                case --stdin --askpass --non-interactive
                    command sudo $argv
                    return
                case '--*'
                case '-*S*' '-*A*' '-*n*'
                    command sudo $argv
                    return
                case -u -g -p -C -D -R -T -U -r -t -h
                    set skip 1
                case '-*'
                case '*'
                    break
            end
        end
        command sudo -A $argv
    end
end
