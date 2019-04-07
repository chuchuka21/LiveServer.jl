@testset "Server/Paths                " begin
    # requested path --> a filesystem path
    bk = pwd()
    cd(dirname(dirname(pathof(LiveServer))))
    req = "tmp"
    @test LS.get_fs_path(req) == ""
    req = "/test/dummies/index.html"
    @test LS.get_fs_path(req) == "test/dummies/index.html"
    cd(bk)
end

#=
NOTE: if extending these tests, please be careful. As they involve @async tasks which,
themselves, spawn async tasks, if your tests fail for some reason you will HAVE to kill
the current Julia session and restart one otherwise the tasks that haven't been killed
due to the tests not being finished properly will keep running and may clash with new
tasks that you will try to start.
=#
@testset "Server/Step-by-step testing " begin
    #
    # STEP 0: cd to dummies
    #
    bk = pwd()
    cd(dirname(dirname(pathof(LiveServer))))
    cd(joinpath("test", "dummies"))
    port = 8123

    isdir("css") && rm("css", recursive=true)
    isfile("tmp.html") && rm("tmp.html")

    write("tmp.html", "blah")
    mkdir("css")
    write("css/foo.css", "body { color: pink; }")

    #
    # STEP 1: launching the listener
    #
    # assert 8000 ≤ port ≦ 9000
    @test_throws ArgumentError serve(port=7000)
    @test_throws ArgumentError serve(port=10000)

    # define filewatcher outside so that can follow it
    fw = LS.SimpleWatcher()
    task = @async serve(fw; port=port)
    sleep(0.1) # give it time to get started

    # there should be a callback associated with fw now
    @test fw.callback !== nothing
    @test fw.status == :runnable
    # the filewatcher should be running
    @test LS.isrunning(fw)
    # it also should be empty thus far
    @test isempty(fw.watchedfiles)

    #
    # STEP 2: triggering a request
    #
    response = HTTP.get("http://localhost:$port/")
    @test response.status == 200
    # the browser script should be appended
    @test String(response.body) == replace(read("index.html", String),
                            "</body>"=>"$(LS.BROWSER_RELOAD_SCRIPT.x)</body>")
    # if one asks for something incorrect, a 404 should be returned
    # XXX ok so actually an ERROR is thrown, that's not good?
    @test_throws HTTP.ExceptionRequest.StatusError HTTP.get("http://localhost:$port/no.html")
    # if one asks for something without a </body>, it should just be appended
    response = HTTP.get("http://localhost:$port/tmp.html")
    @test response.status == 200
    @test String(response.body) == read("tmp.html", String) * LS.BROWSER_RELOAD_SCRIPT.x
    response = HTTP.get("http://localhost:$port/css/foo.css")
    @test String(response.body) == read("css/foo.css", String)
    @test response.status == 200

    # we asked earlier for index.html therefore that file should be followed
    @test fw.watchedfiles[1].path == "index.html"
    # also tmp
    @test fw.watchedfiles[2].path == "tmp.html"
    # and the css
    @test fw.watchedfiles[3].path == "css/foo.css"

    # if we modify the file, it should trigger the callback function which should open
    # and then subsequently close a websocket. We check this happens properly by adding
    # our own sentinel websocket
    sentinel = HTTP.WebSockets.WebSocket(IOBuffer())
    LS.WS_VIEWERS["tmp.html"] = [sentinel]

    @test sentinel.io.writable
    write("tmp.html", "something new")
    sleep(0.1)
    # the sentinel websocket should be closed
    @test !sentinel.io.writable
    # the websockets should have been flushed
    @test isempty(LS.WS_VIEWERS["tmp.html"])

    # let's do this again with an infra file which will ping all websockets
    sentinel1 = HTTP.WebSockets.WebSocket(IOBuffer())
    sentinel2 = HTTP.WebSockets.WebSocket(IOBuffer())
    push!(LS.WS_VIEWERS["tmp.html"], sentinel1)
    LS.WS_VIEWERS["css/foo.css"] = [sentinel2]
    write("css/foo.css", "body { color:blue; }")
    sleep(0.1)
    # all sentinel websockets should be closed
    @test !sentinel1.io.writable
    @test !sentinel2.io.writable

    # if we remove the files, it shall stop following it
    rm("tmp.html")
    rm("css", recursive=true)
    sleep(0.25)
    # only index.html is still watched
    @test length(fw.watchedfiles) == 1

    #
    # SHUTTING DOWN
    #
    # this should have interrupted the server, so it should be possible
    # to restart one on the same port (otherwise this will throw an error, already in use)
    schedule(task, InterruptException(), error=true)
    sleep(0.25) # give it time to get done
    @test istaskdone(task)
    @test begin
        server = Sockets.listen(port)
        sleep(0.1)
        close(server)
        true
    end == true

    # Check that WS_FILES is properly destroyed
    isempty(LS.WS_VIEWERS)

    cd(bk)
end

@testset "Server/ws_tracker testing   " begin
    # bk = pwd()
    # cd(mktempdir())
    # write("ws_TESTFILE.html", "A file") # create a test file to request from
    # empty!(LS.WS_VIEWERS) # make sure list of viewers is empty to start with
    #
    # # start ws server
    # port = 8765
    # server = Sockets.listen(port)
    # task_listen = @async HTTP.listen(Sockets.localhost, port, server=server) do http::HTTP.Stream
    #     if HTTP.WebSockets.is_upgrade(http.message)
    #         LS.ws_tracker(http)
    #     end
    # end
    #
    # # ws client
    # HTTP.WebSockets.open("ws://127.0.0.1:$port/ws_TESTFILE.html") do ws
    #     write(ws, "update")
    #     @test LS.WS_VIEWERS["ws_TESTFILE.html"] isa Vector{HTTP.WebSockets.WebSocket}
    #     @test length(LS.WS_VIEWERS["ws_TESTFILE.html"]) ==  1
    #     throw(InterruptException())
    # end
    #
    # # clean up
    # close(server)
    # schedule(task_ws, InterruptException(), error=true)
    # rm("ws_TESTFILE.html")
    # cd(bk)
end
