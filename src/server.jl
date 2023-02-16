# https://github.com/fonsp/Pluto.jl/blob/bedc7767d76439477bae8a5165f4f39906f9064c/src/notebook/path%20helpers.jl#L3-L8
function detectwsl()
    Sys.islinux() &&
    isfile("/proc/sys/kernel/osrelease") &&
    occursin(r"Microsoft|WSL"i, read("/proc/sys/kernel/osrelease", String))
end

"""
    open_in_default_browser(url)

Open a URL in the ambient default browser.

Note: this was copied from Pluto.jl.
"""
function open_in_default_browser(url::AbstractString)::Bool
    try
        if Sys.isapple()
            Base.run(`open $url`)
            true
        elseif Sys.iswindows() || detectwsl()
            Base.run(`cmd.exe /s /c start "" /b $url`)
            true
        elseif Sys.islinux()
            Base.run(`xdg-open $url`)
            true
        else
            false
        end
    catch ex
        false
    end
end

"""
    update_and_close_viewers!(wss::Vector{HTTP.WebSockets.WebSocket})

Take a list of viewers, i.e. WebSocket connections from a client,
send a message with data "update" to each of them (to trigger a page reload),
then close the connection. Finally, empty the list since all connections are
closing anyway and clients will re-connect from the re-loaded page.
"""
function update_and_close_viewers!(wss::Vector{HTTP.WebSockets.WebSocket})
    ws_to_update_and_close = collect(wss)
    empty!(wss)

    # send update message to all viewers
    @sync for wsi in ws_to_update_and_close
        isopen(wsi.io) && @async begin
            try
                HTTP.WebSockets.send(wsi, "update")
            catch
            end
        end
    end

    # force close all viewers (these will be replaced by 'fresh' ones
    # after the reload triggered by the update message)
    @sync for wsi in ws_to_update_and_close
        isopen(wsi.io) && @async begin
            try
                wsi.writeclosed = wsi.readclosed = true
                close(wsi.io)
            catch
            end
        end
    end

    return nothing
end


"""
    file_changed_callback(f_path::AbstractString)

Function reacting to the change of the file at `f_path`. Is set as callback for
the file watcher.
"""
function file_changed_callback(f_path::AbstractString)
    if VERBOSE[]
        @info "[LiveServer]: Reacting to change in file '$f_path'..."
    end
    if endswith(f_path, ".html")
        # if html file, update viewers of this file only
        # check the viewer still exists otherwise may error
        # see issue https://github.com/asprionj/LiveServer.jl/issues/95
        if haskey(WS_VIEWERS, f_path)
            update_and_close_viewers!(WS_VIEWERS[f_path])
        end
    else
        # otherwise (e.g. modification to a CSS file), update all viewers
        foreach(update_and_close_viewers!, values(WS_VIEWERS))
    end
    return nothing
end


"""
    get_fs_path(req_path::AbstractString)

Return the filesystem path corresponding to a requested path, or an empty
String if the file was not found.

Cases:
    * an explicit request to an existing `index.html` (e.g. `foo/bar/index.html`)
        is given --> serve the page and change WEB_DIR unless a parent dir should
        be preferred (e.g. foo/ has an index.html)
    * an implicit request to an existing `index.html` (e.g. `foo/bar/` or `foo/bar`)
        is given --> same as previous case after appending the `index.html`
    * a request to a file is given (e.g. `/sample.jpeg`) --> figure out what it
        is relative to, reconstruct the full system path and serve the file
    * a request for a dir without index is given (e.g. `foo/bar`) --> serve a
        dedicated index file listing the content of the directory.
"""
function get_fs_path(req_path::AbstractString)::String
    uri     = HTTP.URI(req_path)
    r_parts = HTTP.URIs.unescapeuri.(split(lstrip(uri.path, '/'), '/'))
    fs_path = joinpath(CONTENT_DIR[], r_parts...)

    resolved_fs_path = ""
    cand_index = ifelse(
        r_parts[end] == "index.html",
        fs_path,
        joinpath(fs_path, "index.html")
    )

    if isfile(cand_index)
        resolved_fs_path = cand_index

    elseif isfile(fs_path)
        resolved_fs_path = fs_path

    elseif isdir(fs_path)
        resolved_fs_path = joinpath(fs_path, "")

    end

    DEBUG[] && @info """
        👀 RESOLVE (req: $req_path) 👀
            fs_path:    $(fs_path) ($(resolved_fs_path))
        """
    return resolved_fs_path
end

"""
    lstrip_cdir(s)

Discard the 'CONTENT_DIR' part (passed via `dir=...`) of a path.
"""
function lstrip_cdir(s::AbstractString)
    # we can't easily do a regex match here because CONTENT_DIR may
    # contain regex characters such as `+` or `-`
    ss = string(s)
    if startswith(s, CONTENT_DIR[])
        ss = ss[nextind(s, lastindex(CONTENT_DIR[])):end]
    end
    return string(lstrip(ss, ['/', '\\']))
end

"""
    get_dir_list(dir::AbstractString) -> index_page::AbstractString

Generate list of content at path `dir`.
"""
function get_dir_list(dir::AbstractString)
    list   = readdir(dir; join=true, sort=true)
    io     = IOBuffer()
    sdir   = dir
    cdir   = CONTENT_DIR[]
    if !isempty(cdir)
        sdir = join([cdir, lstrip_cdir(dir)], "/")
    end

    write(io, """
        <!DOCTYPE HTML>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/spcss">
            <title>Directory listing</title>
            <style>
              a {text-decoration: none;}
            </style>
          </head>
          <body>
            <h1 style='margin-top: 1em;'>
              Directory listing
            </h1>
            <h3>
               <a href="/" alt="root">🏠</a>
               <a href="/$(dirname(dir))" alt="parent dir">⬆️</a>
               &nbsp; path: <code style='color:gray;'>$(sdir)</code>
             </h3>

            <hr>
            <ul>
        """
    )

    list_files = [f for f in list if isfile(f)]
    list_dirs  = [d for d in list if d ∉ list_files]

    for fname in list_files
        link  = lstrip_cdir(fname)
        name  = splitdir(fname)[end]
        post  = ifelse(islink(fname), " @", "")
        write(io, """
            <li><a href="/$(link)">$(name)$(post)</a></li>
            """
        )
    end
    for fdir in list_dirs
        link  = lstrip_cdir(fdir)
        # ensure ends with slash, see #135
        link *= ifelse(endswith(link, "/"), "", "/")
        name  = splitdir(fdir)[end]
        pre   = "📂 "
        post  = ifelse(islink(fdir), " @", "")
        write(io, """
            <li><a href="/$(link)">$(pre)$(name)$(post)</a></li>
            """
        )
    end
    write(io, """
            </ul>
            <hr>
            <a href="https://github.com/tlienart/LiveServer.jl">💻 LiveServer.jl</a>
          </body>
        </html>
        """
    )
    return String(take!(io))
end

"""
    serve_file(fw, req::HTTP.Request; inject_browser_reload_script = true)

Handler function for serving files. This takes a file watcher, to which files
to be watched can be added, and a request (e.g. a path entered in a tab of the
browser), and converts it to the appropriate file system path.

The cases are as follows:
 1. FILE: the path corresponds exactly to a file. If it's a html-like file,
     LiveServer will try injecting the reloading `<script>` (see file
     `client.html`) at the end, just before the `</body>` tag. Otherwise
     we let the browser attempt to show it (e.g. if it's an image).
 2. WEB-DIRECTORY: the path corresponds to a directory in which there is an
     `index.html`, same action as (1) assuming the `index.html` is implicit.
 3. PLAIN-DIRECTORY: the path corresponds to a directory in which there is not
     an `index.html`, list the directory contents.
 4. 404: not (1,2,3), a 404 is served.

All files served are added to the file watcher, which is responsible to check
whether they're already watched or not. Finally the file is served via a 200
(successful) response. If the file does not exist, a response with status 404
and message is returned.
"""
function serve_file(
            fw, req::HTTP.Request;
            inject_browser_reload_script::Bool = true,
            allow_cors::Bool = false
        )::HTTP.Response

    #
    # Check if the request is effectively a path to a directory and,
    # if so, whether the path was given with a trailing `/`. If it is
    # a path to a dir but without the trailing slash, send a redirect.
    #
    #   Example: foo/bar        --> foo/bar/
    #            foo/bar?search --> foo/bar/?search
    #            foo/bar#anchor --> foo/bar/#anchor
    #
    uri    = HTTP.URI(req.target)

    DEBUG[] && @info """
        REQUEST ($(req.target))
            uri.path ($(uri.path))
        """

    cand_dir = joinpath(CONTENT_DIR[], split(uri.path, '/')...)
    if !endswith(uri.path, "/") && isdir(cand_dir)
        target = string(HTTP.URI(uri; path=uri.path * "/"))
        DEBUG[] && @info """
            🔃 REDIRECT ($(req.target) --> $target)
            """
        return HTTP.Response(301, ["Location" => target], "")
    end

    ret_code = 200
    fs_path  = get_fs_path(req.target)

    DEBUG[] && @info """
        PATH RESOLUTION ($(req.target))
            fs_path: $(fs_path) [$(ifelse(isempty(fs_path), "❌ ❌ ❌ ", ""))]
        """

    # if get_fs_path returns an empty string, there's two cases:
    # 1. [CASE 3] the path is a directory without an `index.html` --> list dir
    # 2. [CASE 4] otherwise serve a 404 (see if there's a dedicated 404 path,
    if isempty(fs_path)

        if req.target == "/"
            index_page = get_dir_list(".")
            return HTTP.Response(200, index_page)
        end

        ret_code = 404
        # Check if /404/ or /404.html exists and serve that as a body
        for f in ("/404/", "/404.html")
            maybe_path = get_fs_path(f)
            if !isempty(maybe_path)
                fs_path = maybe_path
                break
            end
        end

        # If still not found a body, return a generic error message
        if isempty(fs_path)
            return HTTP.Response(404, """
                404: file not found. Perhaps you made a typo in the URL,
                or the requested file has been deleted or renamed.
                """
            )
        end
    end

    # [CASE 2]
    if isdir(fs_path)
        index_page = get_dir_list(fs_path)
        return HTTP.Response(200, index_page)
    end

    # In what follows, fs_path points to a file
    # --> [CASE 1a] html-like: try to inject reload-script
    # --> [CASE 1b] other: just get the browser to show it
    #
    ext     = lstrip(last(splitext(fs_path)), '.') |> string
    content = read(fs_path, String)

    # build the response with appropriate mime type (this is inspired from Mux
    # https://github.com/JuliaWeb/Mux.jl/blob/master/src/examples/files.jl)
    content_type = let
        mime_from_ext = MIMEs.mime_from_extension(ext, nothing)
        if mime_from_ext !== nothing
            MIMEs.contenttype_from_mime(mime_from_ext)
        else
            HTTP.sniff(content)
        end
    end

    # avoid overly-specific text types so the browser can try rendering
    # all text-like documents instead of offering to download all files
    m = match(r"^text\/(.*?);(.*)$", content_type)
    if m !== nothing
        text_type = m.captures[1]
        if text_type ∉ ("html", "javascript", "css")
            content_type = "text/plain;$(m.captures[2])"
        end
    end
    plain = "text/plain; charset=utf8"
    for p  in ("application/toml", "application/x-sh")
        content_type = replace(content_type, p => plain)
    end

    # if html-like, try adding the browser-sync script to it
    inject_reload = inject_browser_reload_script && (
            startswith(content_type, "text/html") ||
            startswith(content_type, "application/xhtml+xml")
        )

    if inject_reload
        end_body_match = match(r"</body>", content)
        if end_body_match === nothing
            # no </body> tag found, trying to add the reload script at the
            # end. This may fail.
            content *= BROWSER_RELOAD_SCRIPT
        else
            end_body = prevind(content, end_body_match.offset)
            # reconstruct the page with the reloading script
            io = IOBuffer()
            write(io, SubString(content, 1:end_body))
            write(io, BROWSER_RELOAD_SCRIPT)
            write(io, SubString(content, nextind(content, end_body):lastindex(content)))
            content = take!(io)
        end
    end
    
    range_match = match(r"bytes=(\d+)-(\d+)" , HTTP.header(req, "Range", ""))
    is_ranged = !isnothing(range_match)
    

    headers = [
        "Content-Type" => content_type,
    ]
    if is_ranged
        range = parse.(Int, range_match.captures)
        push!(headers, "Content-Range" => "bytes $(range[1])-$(range[2])/$(binary_length(content))")
        content = @view content[1+range[1]:1+range[2]]
        ret_code = 206
    end
    if allow_cors
        push!(headers, "Access-Control-Allow-Origin" => "*")
    end
    push!(headers, "Content-Length" => string(binary_length(content)))
    resp         = HTTP.Response(ret_code, content)
    resp.headers = HTTP.mkheaders(headers)

    # add the file to the file watcher
    watch_file!(fw, fs_path)

    # return the response
    return resp
end

binary_length(s::AbstractString) = ncodeunits(s)
binary_length(s::AbstractVector{UInt8}) = length(s)


"""
    ws_tracker(ws::HTTP.WebSockets.WebSocket, target::AbstractString)

Adds the websocket connection to the viewers in the global dictionary
`WS_VIEWERS` to the entry corresponding to the targeted file.
"""
function ws_tracker(ws::HTTP.WebSockets.WebSocket)
    # NOTE: this file always exists because the query is
    # generated just after serving it
    fs_path = get_fs_path(ws.request.target)

    # add to list of html files being "watched" if the file is already being
    # viewed, add ws to it (e.g. several tabs) otherwise add to dict
    if haskey(WS_VIEWERS, fs_path)
        push!(WS_VIEWERS[fs_path], ws)
    else
        WS_VIEWERS[fs_path] = [ws]
    end

    try
        # NOTE: browsers will drop idle websocket connections so this effectively
        # forces the websocket to stay open until it's closed by LiveServer (and
        # not by the browser) upon writing a `update` message on the websocket.
        # See update_and_close_viewers
        while isopen(ws.io)
            sleep(0.1)
        end
    catch err
        # NOTE: there may be several sources of errors caused by the precise moment
        # at which the user presses CTRL+C and after what events. In an ideal world
        # we would check that none of these errors have another source but for now
        # we make the assumption it's always the case (note that it can cause other
        # errors than InterruptException, for instance it can cause errors due to
        # stream not being available etc but these all have the same source).
        # - We therefore do not propagate the error but merely store the information
        # that there was a forcible interruption of the websocket so that the
        # interruption can be guaranteed to be propagated.
        WS_INTERRUPT[] = true
    end
    return nothing
end


"""
    serve(filewatcher; ...)

Main function to start a server at `http://host:port` and render what is in the current
directory. (See also [`example`](@ref) for an example folder).

# Arguments

    `filewatcher`: a file watcher implementing the API described for
                    [`SimpleWatcher`](@ref) (which also is the default) and
                    messaging the viewers (via WebSockets) upon detecting file
                    changes.
    `port`: integer between 8000 (default) and 9000.
    `dir`: string specifying where to launch the server if not the current
        working directory.
    `verbose`: boolean switch to make the server print information about file
                changes and connections.
    `debug`: bolean switch to make the server print debug messages.
    `coreloopfun`: function which can be run every 0.1 second while the
                    liveserver is running; it takes two arguments: the cycle
                    counter and the filewatcher. By default the coreloop does
                    nothing.
    `launch_browser`: boolean specifying whether to launch the ambient browser
                       at the localhost or not (default: false).
    `allow_cors`: boolean allowing cross origin (CORS) requests to access the
                   server via the "Access-Control-Allow-Origin" header.
    `preprocess_request`: function specifying the transformation of a request
                           before it is returned; its only argument is the
                           current request.
 # Example

 ```julia
 LiveServer.example()
 serve(host="127.0.0.1", port=8080, dir="example", launch_browser=true)
 ```

 You should then see the `index.html` page from the `example` folder being
 rendered. If you change the file, the browser will automatically reload the
 page and show the changes.
 """
 function serve(
             fw::FileWatcher=SimpleWatcher(file_changed_callback);
             # kwargs
             host::String = "127.0.0.1",
             port::Int = 8000,
             dir::AbstractString = "",
             verbose::Bool = false,
             debug::Bool = false,
             coreloopfun::Function = (c, fw)->nothing,
             preprocess_request::Function = identity,
             inject_browser_reload_script::Bool = true,
             launch_browser::Bool = false,
             allow_cors::Bool = false
         )::Nothing

    8000 ≤ port ≤ 9000 || throw(
        ArgumentError("The port must be between 8000 and 9000.")
    )
    set_verbose(verbose)
    set_debug(debug)

    if !isempty(dir)
        isdir(dir) || throw(
            ArgumentError("The specified dir '$dir' is not recognised.")
        )
        set_content_dir(dir)
    end

    start(fw)

    # make request handler
    req_handler = HTTP.Handlers.streamhandler() do req
        req = preprocess_request(req)
        serve_file(
            fw, req;
            inject_browser_reload_script = inject_browser_reload_script,
            allow_cors = allow_cors
        )
    end

    server, port = get_server(host, port, req_handler)
    host_str     = ifelse(host == string(Sockets.localhost), "localhost", host)
    url          = "http://$host_str:$port"
    println(
        "✓ LiveServer listening on $url/ ...\n  (use CTRL+C to shut down)"
    )

    launch_browser && open_in_default_browser(url)
    # wait until user interrupts the LiveServer (using CTRL+C).
    try
        counter = 1
        while true
            if WS_INTERRUPT[] || fw.status == :interrupted
                # rethrow the interruption (which may have happened during
                # the websocket handling or during the file watching)
                throw(InterruptException())
            end
            # do the auxiliary function if there is one (by default this does nothing)
            coreloopfun(counter, fw)
            # update the cycle counter and sleep (yields to other threads)
            counter += 1
            sleep(0.1)
        end
    catch err
        if !isa(err, InterruptException)
            if VERBOSE[]
                @error "serve error" exception=(err, catch_backtrace())
            end
            throw(err)
        end
    finally
        # cleanup: close everything that might still be alive
        print("\n⋮ shutting down LiveServer… ")
        # stop the filewatcher
        stop(fw)
        # close any remaining websockets
        for wss ∈ values(WS_VIEWERS)
            @sync for wsi in wss
                isopen(wsi.io) && @async begin
                    try
                        wsi.writeclosed = wsi.readclosed = true
                        close(wsi.io)
                    catch
                    end
                end
            end
        end
        # empty the dictionary of viewers
        empty!(WS_VIEWERS)
        # shut down the server
        HTTP.Servers.forceclose(server)
        # reset other environment variables
        reset_content_dir()
        reset_ws_interrupt()
        println("✓")
    end
    return nothing
end

function get_server(host, port, req_handler; incr=0)
    if incr >= 10
        @error "couldn't find a free port in $incr tries"
    end
    try
        server = HTTP.listen!(host, port; readtimeout=0) do http::HTTP.Stream
            if HTTP.WebSockets.isupgrade(http.message)
                # upgrade to websocket and add to list of viewers and keep open
                # until written to
                HTTP.WebSockets.upgrade(ws_tracker, http)
            else
                # handle HTTP request
                return req_handler(http)
            end
        end
        return server, port
    catch IOError
        return get_server(host, port+1, req_handler; incr=incr+1)
    end
end
