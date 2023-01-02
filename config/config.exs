import Config

config :xmavlink, dialect: Common, connections: ["udpin:192.168.0.101:15550", "udpout:127.0.0.1:14550", "tcpout:127.0.0.1:5760"] # Common, QGC (HAS to be loopback), SITL
config :logger, level: :warn
