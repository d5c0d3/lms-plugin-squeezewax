# Disposable LMS 9.2 whose DBD::SQLite is 1.58 / SQLite 3.22.0 on perl 5.32 -
# the pairing a forum tester's piCorePlayer reported (decisions §15.42).
# debian:bullseye-slim ships perl 5.32.1, x86_64-linux-gnu-thread-multi.
FROM debian:bullseye-slim

ARG LMS_COMMIT=eb59bbf8c82827f61d192aa30152d3ed539c92e5
ARG DBD_SQLITE=1.58
ARG UID=1000

ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8

# Bullseye is end-of-life; its pools moved to archive.debian.org.
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list && \
	echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99archive

# Runtime packages as in slimserver's .devcontainer/Dockerfile, plus the build
# toolchain for DBD::SQLite, plus flac/sox for making the test albums.
RUN apt-get update -qq && \
	apt-get install --no-install-recommends -qy ca-certificates git procps curl perl tzdata \
		libcrypt-blowfish-perl libwww-perl libfont-freetype-perl liblinux-inotify2-perl \
		libdata-dump-perl libio-socket-ssl-perl libnet-ssleay-perl libcrypt-ssleay-perl \
		libcrypt-openssl-rsa-perl libssl-dev libgomp1 libasound2 \
		build-essential cpanminus flac sox libsox-fmt-all && \
	rm -rf /var/lib/apt/lists/*

# LMS source, pinned to one commit of public/9.2.
RUN git init -q /opt/lms && cd /opt/lms && \
	git fetch -q --depth 1 https://github.com/LMS-Community/slimserver.git ${LMS_COMMIT} && \
	git checkout -q FETCH_HEAD && rm -rf .git

# Build DBD::SQLite ${DBD_SQLITE} (bundles SQLite 3.22.0) and overlay it onto LMS's
# own CPAN/arch/5.32 tree: the .pm, the DBD/SQLite/ helpers and the .so. Nothing
# else in the tree changes. LMS's DBI (1.628) stays.
RUN cpanm --notest -L /opt/dbd DBD::SQLite@${DBD_SQLITE} && \
	A=/opt/lms/CPAN/arch/5.32 && L=/opt/dbd/lib/perl5/x86_64-linux-gnu-thread-multi && \
	rm -rf $A/DBD/SQLite.pm $A/DBD/SQLite \
		$A/x86_64-linux-thread-multi/auto/DBD/SQLite && \
	cp $L/DBD/SQLite.pm $A/DBD/SQLite.pm && cp -r $L/DBD/SQLite $A/DBD/SQLite && \
	mkdir -p $A/x86_64-linux-thread-multi/auto/DBD/SQLite && \
	cp $L/auto/DBD/SQLite/SQLite.so $A/x86_64-linux-thread-multi/auto/DBD/SQLite/ && \
	rm -rf /opt/dbd /root/.cpanm

RUN useradd -m -u ${UID} lms && mkdir -p /data /music && chown lms /data
USER lms
EXPOSE 9000
CMD ["perl", "/opt/lms/slimserver.pl", "--prefsdir", "/data/prefs", "--cachedir", "/data/cache", \
	"--logdir", "/data/logs", "--httpport", "9000"]
