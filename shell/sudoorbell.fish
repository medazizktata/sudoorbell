# sudoorbell shell integration for fish, sourced from config.fish by
# `sudoorbell install`, which also sets SUDOORBELL_HOME. Same behaviour as
# shell/sudoorbell.sh: export SUDO_ASKPASS, and add -A when there is no
# terminal.

if set -q SUDOORBELL_HOME; and test -x "$SUDOORBELL_HOME/libexec/sudoorbell-askpass"
    # A program that brings its own askpass (Cursor's agent does) keeps it.
    if not set -q SUDO_ASKPASS; or string match -q '*/libexec/sudoorbell-askpass' -- $SUDO_ASKPASS
        set -gx SUDO_ASKPASS "$SUDOORBELL_HOME/libexec/sudoorbell-askpass"
    end

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
        # Turned off for the program this shell runs for (`sudoorbell client`):
        # sudo as if sudoorbell were not here.
        if not sh -c '. "$SUDOORBELL_HOME/lib/sudoorbell.sh" && sd_client_enabled "$(sd_requester "$1")"' sh $fish_pid
            command sudo $argv
            return
        end
        # macOS skips Touch ID when sudo is given -A. So with Touch ID on,
        # start sudo without -A and with DISPLAY set: with no terminal and a
        # display, sudo uses SUDO_ASKPASS by itself, after Touch ID.
        set -l touch_id $SUDOORBELL_TOUCH_ID
        if test -z "$touch_id"
            set -l conf (set -q XDG_CONFIG_HOME; and echo $XDG_CONFIG_HOME; or echo $HOME/.config)/sudoorbell/config
            set touch_id (sed -n 's/^[[:space:]]*touch_id[[:space:]]*=[[:space:]]*//p' $conf 2>/dev/null | sed 's/[[:space:]]*$//' | tail -n 1)
        end
        if test (uname -s) = Darwin; and test "$touch_id" != off
            and grep -q -E '^[[:space:]]*auth[[:space:]].*pam_(tid|watchid)\.so' /etc/pam.d/sudo_local /etc/pam.d/sudo 2>/dev/null
            set -q DISPLAY; or set -lx DISPLAY sudoorbell
            command sudo $argv
            return
        end
        command sudo -A $argv
    end
end
