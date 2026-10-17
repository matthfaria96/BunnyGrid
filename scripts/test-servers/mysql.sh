#!/bin/sh
# Throwaway MySQL server for the integration tests, without touching the system's MySQL config or data:
# everything (data, socket, pid, log, certificates) lives in one folder.
#
#   scripts/test-servers/mysql.sh start [DIR]   # initializes on first use, prints the env for `swift test`
#   scripts/test-servers/mysql.sh env [DIR]     # prints the env again
#   scripts/test-servers/mysql.sh stop [DIR]
#
# DIR defaults to $TMPDIR/bunnygrid-mysql; BUNNYGRID_MYSQL_PORT (default 33071) picks the port.
# Users: root (no password, socket/localhost), bunny / bunnypass (any host, TCP or TLS),
# certuser (REQUIRE X509, client certificate in DIR/certs). require_secure_transport stays off.
set -eu

cmd=${1:-}
dir=${2:-${TMPDIR:-/tmp}/bunnygrid-mysql}
port=${BUNNYGRID_MYSQL_PORT:-33071}
mysqld=${MYSQLD:-mysqld}
mysql=${MYSQL:-mysql}
certs="$dir/certs"
sock="$dir/mysql.sock"
# Unix socket paths are limited to 104 bytes; a deep DIR gets a short symlink in $TMPDIR instead.
link="${TMPDIR:-/tmp}"
link="${link%/}/bunnygrid-mysql-$port"
if [ ${#sock} -gt 100 ]; then sock="$link/mysql.sock"; fi

make_certs() {
    mkdir -p "$certs"
    cd "$certs"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 365 -subj "/CN=BunnyGrid Test CA" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout server-key.pem -out server.csr -subj "/CN=localhost" 2>/dev/null
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > san.ext
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server-cert.pem -days 365 -extfile san.ext 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout client-key.pem -out client.csr -subj "/CN=certuser" 2>/dev/null
    openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out client-cert.pem -days 365 2>/dev/null
    cd - >/dev/null
}

print_env() {
    cat <<EOF
export BUNNYGRID_MYSQL_PORT=$port BUNNYGRID_MYSQL_HOST=127.0.0.1 BUNNYGRID_MYSQL_USER=bunny BUNNYGRID_MYSQL_PASSWORD=bunnypass
export BUNNYGRID_MYSQL_SSL_CA=$certs/ca.pem BUNNYGRID_MYSQL_SSL_CERT=$certs/client-cert.pem BUNNYGRID_MYSQL_SSL_KEY=$certs/client-key.pem BUNNYGRID_MYSQL_SSL_USER=certuser
export BUNNYGRID_MYSQL_SOCKET=$sock
EOF
}

case "$cmd" in
start)
    mkdir -p "$dir"
    case "$sock" in "$link"/*) ln -sfn "$dir" "$link" ;; esac
    [ -f "$certs/ca.pem" ] || make_certs
    fresh=0
    if [ ! -d "$dir/data" ]; then
        # --no-defaults keeps Homebrew's /opt/homebrew/etc/my.cnf (and ~/.my.cnf) out of it.
        "$mysqld" --no-defaults --initialize-insecure --datadir="$dir/data" --log-error="$dir/init.log"
        fresh=1
    fi
    "$mysqld" --no-defaults --datadir="$dir/data" --port="$port" --bind-address=127.0.0.1 \
        --socket="$sock" --pid-file="$dir/mysqld.pid" --log-error="$dir/mysqld.log" \
        --mysqlx=OFF --require-secure-transport=OFF \
        --ssl-ca="$certs/ca.pem" --ssl-cert="$certs/server-cert.pem" --ssl-key="$certs/server-key.pem" \
        >/dev/null 2>&1 &
    i=0
    until "$mysql" --no-defaults -uroot -S "$sock" -e 'SELECT 1' >/dev/null 2>&1; do
        i=$((i + 1))
        [ $i -gt 60 ] && { echo "mysqld did not start; see $dir/mysqld.log" >&2; exit 1; }
        sleep 1
    done
    if [ $fresh = 1 ]; then
        "$mysql" --no-defaults -uroot -S "$sock" <<'SQL'
CREATE USER 'bunny'@'%' IDENTIFIED BY 'bunnypass';
GRANT ALL PRIVILEGES ON *.* TO 'bunny'@'%' WITH GRANT OPTION;
CREATE USER 'certuser'@'%' REQUIRE X509;
GRANT SELECT ON *.* TO 'certuser'@'%';
CREATE USER 'nopass'@'%';
GRANT ALL PRIVILEGES ON *.* TO 'nopass'@'%';
SQL
    fi
    echo "mysqld running on 127.0.0.1:$port (socket $sock)"
    print_env
    ;;
env)
    print_env
    ;;
stop)
    if [ -f "$dir/mysqld.pid" ]; then
        pid=$(cat "$dir/mysqld.pid")
        kill "$pid" 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do sleep 1; done
        echo "mysqld stopped"
        [ -L "$link" ] && rm -f "$link"
    else
        echo "no mysqld.pid in $dir" >&2
    fi
    ;;
*)
    echo "usage: $0 start|env|stop [DIR]" >&2
    exit 2
    ;;
esac
