(function (exports) {
  exports.navigator.getUserMedia = getUserMedia
  exports.AudioContext = exports.webkitAudioContext || exports.AudioContext
  exports.AudioContext.prototype.createMediaStreamSource = createMediaStreamSource
  exports.AudioContext.prototype.createScriptProcessor = createScriptProcessor

  var tracks = {}
  var callbacks = getUserMedia._callbacks = {}

  getUserMedia._onmedia = function (kind, data) {
    var tracksByKind = tracks[kind]

    if (kind === 'audio') {
      data = new Float32Array(base64ToData(data))
    } else if (kind === 'video') {
      data = data
    }

    for (var i in tracksByKind) {
      var track = tracksByKind[i]
      track._ondataavailable && track._ondataavailable(data)
    }
  }

  function getUserMedia (constraints, successCallback, errorCallback) {
    postMessage('GetUserMediaShim_MediaStream_new', constraints, function (trackData) {
      var stream = new MediaStream()

      for (var i in trackData) {
        var data = trackData[i]
        var track = new MediaStreamTrack()

        track.id = data.id
        track.kind = data.kind
        track._meta = data.meta
        track._stream = stream

        stream._tracks.push(track)
        tracks[track.kind] = tracks[track.kind] || {}
        tracks[track.kind][track.id] = track
      }

      successCallback(stream)
    }, errorCallback)
  }

  // MediaStreamAudioSourceNode

  function createMediaStreamSource (stream) {
    return new MediaStreamAudioSourceNode(stream)
  }

  function MediaStreamAudioSourceNode (stream) {
    this.mediaStream = stream

    for (var i in stream._tracks) {
      var track = stream._tracks[i]
      if (track.kind === 'audio') {
        this._track = track
        break
      }
    }

    if (this._track) {
      this.channelCount = this._track._meta.channelCount
      this._track._ondataavailable = this._ondataavailable.bind(this)
    } else {
      this.channelCount = 1
    }

    this._connections = []
    this._context = MediaStreamAudioSourceNode.context = MediaStreamAudioSourceNode.context || new exports.AudioContext()
  }

  MediaStreamAudioSourceNode.prototype._ondataavailable = function (data) {
    var evt = new window.Event('audioprocess')
    evt.inputBuffer = this._context.createBuffer(this._track._meta.channelCount, data.length, this._track._meta.sampleRate)
    evt.inputBuffer.getChannelData(0).set(data)

    for (var i in this._connections) {
      var connection = this._connections[i]
      connection.onaudioprocess && connection.onaudioprocess(evt)
    }
  }

  MediaStreamAudioSourceNode.prototype.connect = function (node) {
    this._connections.push(node)
  }

  MediaStreamAudioSourceNode.prototype.disconnect = function (node) {
    for (var i = 0; i < this._connections.length; i++) {
      if (this._connections[i] === node) {
        this._connections.splice(i, 1)
        break
      }
    }
  }

  // ScriptProcessorNode

  function createScriptProcessor () {
    return new _ScriptProcessorNode()
  }

  function _ScriptProcessorNode () {}

  _ScriptProcessorNode.prototype.connect = function () {}

  _ScriptProcessorNode.prototype.disconnect = function () {}

  // MediaStream

  function MediaStream () {
    this._tracks = []
    this.active = true
  }

  MediaStream.prototype.getTracks = function () {
    return this._tracks
  }

  MediaStream.prototype.stop = function () {
    this.active = false

    for (var i in this._tracks) {
      this._tracks[i].stop()
    }

    // TODO dispatchEvent how?
    this.oninactive && this.oninactive()
  }

  // MediaStreamTrack

  function MediaStreamTrack () {
    this.readyState = 'live'
  }

  MediaStreamTrack.prototype.stop = function () {
    if (this.readyState !== 'live') {
      return
    }

    this.readyState = 'ended'

    window.webkit.messageHandlers['GetUserMediaShim_MediaStreamTrack_stop'].postMessage({
      id: this.id
    })

    if (this._stream.active) {
      var streamHasLiveTrack = false

      for (var i in this._stream._tracks) {
        if (this._stream._tracks[i].readyState === 'live') {
          streamHasLiveTrack = true
          break
        }
      }

      if (!streamHasLiveTrack) {
        this._stream.stop()
      }
    }
  }

  // ipc utilities

  function postMessage (name, params, onsuccess, onerror) {
    params.onsuccess = registerCallback(function (obj) {
      deregisterCallback(params.onsuccess)
      deregisterCallback(params.onerror)
      onsuccess(obj)
    })

    params.onerror = registerCallback(function (err) {
      deregisterCallback(params.onsuccess)
      deregisterCallback(params.onerror)
      onerror(err)
    })

    window.webkit.messageHandlers[name].postMessage(params)
  }

  function registerCallback (cb) {
    var id = genUniqueId(callbacks)
    callbacks[id] = cb
    return id
  }

  function deregisterCallback (id) {
    delete callbacks[id]
  }

  function genUniqueId (lookup) {
    var id = genId()

    while (lookup[id]) {
      id = genId()
    }

    return id
  }

  function genId () {
    return Math.random().toString().slice(2)
  }

  function base64ToData (string) {
    var binaryString = window.atob(string)
    var len = binaryString.length
    var bytes = new Uint8Array(len)

    for (var i = 0; i < len; i++) {
      bytes[i] = binaryString.charCodeAt(i)
    }

    return bytes.buffer
  }

})(window)
