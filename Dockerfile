FROM alpine:3.22

# pg_dump must be >= server major version (it can dump older servers, not newer).
ARG PG_MAJOR=17

RUN apk add --no-cache bash coreutils curl tzdata supercronic sqlite mariadb-client \
      "postgresql${PG_MAJOR}-client" \
 && mkdir /backup

COPY --chmod=755 bkdb.sh /usr/local/bin/bkdb.sh

VOLUME /backup

ENTRYPOINT ["bkdb.sh"]
CMD ["cron"]
