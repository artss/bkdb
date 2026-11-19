FROM alpine:3.24

# pg_dump must be >= server major version (it can dump older servers, not newer).
ARG PG_MAJOR=18

RUN apk add --no-cache bash coreutils curl tzdata supercronic sqlite mariadb-client \
      "postgresql${PG_MAJOR}-client" \
 && mkdir /backup

COPY --chmod=755 bkdb.sh /usr/local/bin/bkdb.sh

VOLUME /backup

ENTRYPOINT ["bkdb.sh"]
CMD ["cron"]
