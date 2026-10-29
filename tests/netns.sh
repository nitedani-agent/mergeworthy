#!/bin/bash
# netns-run: a server on a port inside doesn't hold that port on the host, names resolve inside, and the command's status comes back.
R=$(readlink -f "${1:-$(dirname "$0")/..}"); fails=0
check() { echo "$1: $3 (want $2)"; [ "$2" = "$3" ] || fails=$((fails+1)); }
if ! command -v slirp4netns >/dev/null; then echo "netns-run: slirp4netns missing, skipped"; exit 0; fi
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
py=$(python3 -c "import sys; print(sys.executable)")  # the interpreter itself: a version-manager shim would be the PID killed, leaving the server
inside=$("$R/bin/netns-run" bash -c "$py -m http.server $port --bind 127.0.0.1 >/dev/null 2>&1 & p=\$!; for i in \$(seq 50); do curl -s -o /dev/null http://127.0.0.1:$port/ && break; sleep 0.1; done; curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/; kill -9 \$p")  # netns-run's shell ignores SIGTERM, and so does what it starts
check "a server inside answers inside" 200 "$inside"
check "the host doesn't see that port" 0 "$(ss -ltn | grep -c ":$port ")"
sleep 0.3; check "the server is gone once the command ends" 0 "$(pgrep -f "^$py -m http.server $port " | wc -l)"
"$R/bin/netns-run" bash -c 'exit 7'; check "the command's exit status comes back" 7 "$?"
check "the namespace has a route out (tap0)" 1 "$("$R/bin/netns-run" ip route | grep -c '^default via 10.0.2.2 dev tap0')"
check "DNS inside goes to slirp4netns's forwarder, not a host stub like 127.0.0.53" "nameserver 10.0.2.3" "$("$R/bin/netns-run" grep -m1 '^nameserver' /etc/resolv.conf)"
check "a name resolves inside" 0 "$("$R/bin/netns-run" getent hosts github.com >/dev/null; echo $?)"
check "the host's search domains stay" "$(grep -E '^search[[:space:]]' /etc/resolv.conf)" "$("$R/bin/netns-run" grep -E '^search[[:space:]]' /etc/resolv.conf)"
check "the command runs as the caller's uid, with the caller's home" "$(id -u) $(getent passwd "$(id -u)" | cut -d: -f6)" "$("$R/bin/netns-run" bash -c 'echo "$(id -u) $(getent passwd "$(id -u)" | cut -d: -f6)"')"
echo "failures: $fails"; [ "$fails" = 0 ]
