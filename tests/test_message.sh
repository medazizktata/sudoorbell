#!/bin/sh
# What the dialog says.
. "$(dirname "$0")/helpers.sh"
. "$root/lib/sudo-dialog.sh"

m=$(sd_message "sudo -A apt install curl" codex 1)
assert_contains "names the command" "$m" "sudo -A apt install curl"
assert_contains "names the requester" "$m" "Requested by: codex"
assert_not_contains "first attempt has no retry line" "$m" "Wrong password"

m=$(sd_message "sudo true" codex 2)
assert_contains "second attempt says so" "$m" "Wrong password. Attempt 2."

m=$(sd_message "sudo true" "" 1)
assert_not_contains "no requester line when unknown" "$m" "Requested by"

assert_eq "markup is escaped" "$(printf '%s' 'a <b>&</b>' | sd_escape_markup)" 'a &lt;b&gt;&amp;&lt;/b&gt;'

finish
