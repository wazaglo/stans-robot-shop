#
# Build
#
FROM maven:3.8.8-eclipse-temurin-8 AS build

WORKDIR /opt/shipping

COPY pom.xml .
RUN mvn dependency:resolve

COPY src ./src
RUN mvn package

#
# Run
#
FROM eclipse-temurin:8-jdk

EXPOSE 8080

WORKDIR /opt/shipping

ENV CART_ENDPOINT=cart:8080
ENV DB_HOST=mysql

COPY --from=build /opt/shipping/target/shipping-1.0.jar shipping.jar

CMD ["java", "-Xmn64m", "-Xmx144m", "-XX:MaxMetaspaceSize=48m", "-XX:+ExitOnOutOfMemoryError", "-jar", "shipping.jar"]
