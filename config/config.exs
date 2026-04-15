import Config

config :volt,
  define: %{"process.env.NODE_ENV" => ~s("production")},
  aliases: %{"@reach" => "assets/js"}
