FROM node:16

COPY ./ /var/apps/acmeair-nodejs

RUN \
  rm -fr /var/apps/acmeair-nodejs/.git ;\
  cd /var/apps/acmeair-nodejs ;\
  npm install;\
  chmod +x run.sh


WORKDIR /var/apps/acmeair-nodejs

EXPOSE 9080 9443

ENV APP_NAME app.js

# Use the following to indicate authentication micro-service location: host:port
#ENV AUTH_SERVICE

# Use the following environment variable to define datasource location
#ENV MONGO_URL mongodb://localhost:27017/acmeair
#ENV CLOUDANT_URL


CMD ["./run.sh"]
