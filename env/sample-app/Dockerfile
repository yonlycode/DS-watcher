FROM node:20-alpine

WORKDIR /app

COPY server.js /app/server.js

ENV PORT=3000
ENV APP_VERSION=1.0.0
ENV FAIL_HEALTH=false

HEALTHCHECK --interval=2s --timeout=1s --retries=2 --start-period=2s \
  CMD wget -q -O - http://127.0.0.1:3000/health || exit 1

EXPOSE 3000

CMD ["node", "server.js"]
