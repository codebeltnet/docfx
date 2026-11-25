ARG NGINX_IMAGE=dhi.io/nginx:1.31-alpine@sha256:d319254f901133993ea3308d9266f29dada690b0bd20ea756b6d18d6fb99a0da

FROM --platform=$BUILDPLATFORM ${NGINX_IMAGE} AS verify
COPY site/ /site/
COPY nginx.conf /etc/nginx/conf.d/default.conf
RUN test -s /site/framework-views.json && nginx -t

FROM ${NGINX_IMAGE}
COPY --from=verify /site/ /usr/share/nginx/html/
COPY --from=verify /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf
