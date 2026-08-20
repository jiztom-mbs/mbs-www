# The collector image: a docker client, jq, and nothing else.
#
# Built rather than using docker:cli directly so jq is baked in — installing it at
# every container start would mean a restart during a network blip leaves the
# collector unable to write anything.
FROM docker:cli

RUN apk add --no-cache jq

COPY collect.sh /usr/local/bin/collect.sh
# net.sh is separate so its /proc parsing can be run against fixtures off the
# host — see test-net.sh. collect.sh invokes it by this path.
COPY net.sh     /usr/local/bin/net.sh
RUN chmod +x /usr/local/bin/collect.sh /usr/local/bin/net.sh

# A plain loop rather than cron: one process, its logs go to `docker logs`, and
# the interval is visible here instead of hidden in a crontab.
CMD ["sh", "-c", "while true; do /usr/local/bin/collect.sh || echo 'collect failed'; sleep 30; done"]
