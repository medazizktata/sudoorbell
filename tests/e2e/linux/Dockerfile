# A Linux desktop in a box for the end-to-end test: real sudo, real zenity on
# a virtual X display (Xvfb), and xdotool to type into the dialog.
FROM ubuntu:24.04
RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		sudo zenity xvfb xdotool tmux procps util-linux jq perl ca-certificates dbus-x11
RUN useradd -m -s /bin/bash tester \
	&& echo 'tester:correct-horse' | chpasswd \
	&& echo 'tester ALL=(ALL) ALL' >/etc/sudoers.d/tester
COPY . /src
USER tester
WORKDIR /home/tester
CMD ["sh", "/src/tests/e2e/linux/e2e.sh"]
