# The deployer: node for the receiver, git to fetch, docker to run builds.
#
# The docker CLI here talks to the host daemon through the mounted socket, so
# builds run as SIBLING containers rather than nested ones. That keeps this image
# small and means a build cannot see anything this container can.
FROM node:22-alpine

RUN apk add --no-cache git docker-cli

COPY deployer.mjs /usr/local/bin/deployer.mjs
COPY deploy.sh    /usr/local/bin/deploy.sh
RUN chmod +x /usr/local/bin/deploy.sh

CMD ["node", "/usr/local/bin/deployer.mjs"]
