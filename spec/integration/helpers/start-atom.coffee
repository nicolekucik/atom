path = require "path"
temp = require("temp").track()
remote = require "remote"
async = require "async"
{map, extend, once} = require "underscore-plus"
{spawn, spawnSync} = require "child_process"
webdriverio = require "../../../build/node_modules/webdriverio"

AtomPath = remote.process.argv[0]
AtomLauncherPath = path.join(__dirname, "..", "helpers", "atom-launcher.sh")
SocketPath = path.join(temp.mkdirSync("socket-dir"), "atom.sock")
ChromedriverPort = 9515

buildAtomClient = (args, env) ->
  client = webdriverio.remote(
    host: 'localhost'
    port: ChromedriverPort
    desiredCapabilities:
      browserName: "atom"
      chromeOptions:
        binary: AtomLauncherPath
        args: [
          "atom-path=#{AtomPath}"
          "atom-args=#{args.join(" ")}"
          "atom-env=#{map(env, (value, key) -> "#{key}=#{value}").join(" ")}"
          "dev"
          "safe"
          "user-data-dir=#{temp.mkdirSync('atom-user-data-dir')}"
          "socket-path=#{SocketPath}"
        ])

  isRunning = false
  client.on "init", -> isRunning = true
  client.on "end", -> isRunning = false

  client
    .addCommand "waitUntil", (conditionFn, timeout, cb) ->
      timedOut = succeeded = false
      pollingInterval = Math.min(timeout, 100)
      setTimeout((-> timedOut = true), timeout)
      async.until(
        (-> succeeded or timedOut),
        ((next) =>
          setTimeout(=>
            conditionFn.call(this).then(
              ((result) ->
                succeeded = result
                next()),
              ((err) -> next(err))
            )
          , pollingInterval)),
        ((err) -> cb(err, succeeded)))

    .addCommand "waitForWindowCount", (count, timeout, cb) ->
      @waitUntil(
        (-> @windowHandles().then(({value}) -> value.length is count)),
        timeout)
      .then((result) -> expect(result).toBe(true))
      .windowHandles(cb)

    .addCommand "waitForPaneItemCount", (count, timeout, cb) ->
      @waitUntil(
        (-> @execute((-> atom.workspace.getActivePane().getItems().length)).then ({value}) -> value is count),
        timeout)
      .then (result) ->
        expect(result).toBe(true)
        cb(null)

    .addCommand "startAnotherWindow", (args, env, done) ->
      @call ->
        if isRunning
          spawnSync(AtomPath, args.concat([
            "--dev"
            "--safe"
            "--socket-path=#{SocketPath}"
          ]), env: extend({}, process.env, env))
        done()

module.exports = (args, env, fn) ->
  chromedriver = spawn("chromedriver", [
    "--verbose",
    "--port=#{ChromedriverPort}",
    "--url-base=/wd/hub"
  ])

  chromedriverExit = new Promise (resolve, reject) ->
    errorCode = null
    logs = []
    chromedriver.on "exit", (code, signal) ->
      errorCode = code unless signal?
    chromedriver.stderr.on "data", (log) ->
      logs.push(log.toString())
    chromedriver.stderr.on "close", ->
      if errorCode?
        reject("Chromedriver failed. Code: #{errorCode}. Logs: #{logs.join("\n")}")
      else
        resolve()

  waitsFor("webdriver to finish", (done) ->
    finish = once ->
      client
        .end()
        .then(-> chromedriver.kill())
        .then(chromedriverExit.then(
          done,
          (message) ->
            jasmine.getEnv().currentSpec.fail(message)
            done()))

    client = buildAtomClient(args, env)

    client.on "error", ({err, body}) ->
      jasmine.getEnv().currentSpec.fail(err ? body.value.message)
      finish()

    fn(client.init()).then(finish)
  , 30000)
