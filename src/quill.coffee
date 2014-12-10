_             = require('lodash')
pkg           = require('../package.json')
Delta         = require('rich-text/lib/delta')
EventEmitter2 = require('eventemitter2').EventEmitter2
dom           = require('./lib/dom')
Editor        = require('./core/editor')
Formatter     = require('./core/formatter')
Range         = require('./lib/range')


class Quill extends EventEmitter2
  @version: pkg.version
  @editors: []

  @embeds: {}
  @formats: {}
  @modules: {}
  @themes: {}

  @DEFAULTS:
    embeds: ['image']
    formats: ['align', 'bold', 'italic', 'strike', 'underline', 'color', 'background', 'font', 'size', 'link', 'bullet', 'list' ]
    modules:
      'keyboard': true
      'paste-manager': true
      'undo-manager': true
    pollInterval: 100
    readOnly: false
    styles: {}
    theme: 'base'

  @events:
    MODULE_INIT      : 'module-init'
    POST_EVENT       : 'post-event'
    PRE_EVENT        : 'pre-event'
    SELECTION_CHANGE : 'selection-change'
    TEXT_CHANGE      : 'text-change'

  @sources: Editor.sources

  @registerEmbed: (name, embed, number) ->
    console.warn("Overwriting #{name} embed") if Quill.embeds[name]?
    Quill.embeds[name] = [embed, number]

  @registerFormat: (name, format, order) ->
    console.warn("Overwriting #{name} format") if Quill.formats[name]?
    Quill.formats[name] = [format, order]

  @registerModule: (name, module) ->
    console.warn("Overwriting #{name} module") if Quill.modules[name]?
    Quill.modules[name] = module

  @registerTheme: (name, theme) ->
    console.warn("Overwriting #{name} theme") if Quill.themes[name]?
    Quill.themes[name] = theme

  @require: (name) ->
    switch name
      when 'lodash' then return _
      when 'delta' then return Delta
      when 'dom' then return dom
      else return null


  constructor: (@container, options = {}) ->
    @container = document.querySelector(container) if _.isString(@container)
    throw new Error('Invalid Quill container') unless @container?
    moduleOptions = _.defaults(options.modules or {}, Quill.DEFAULTS.modules)
    html = @container.innerHTML
    @container.innerHTML = ''
    @options = _.defaults(options, Quill.DEFAULTS)
    @options.modules = moduleOptions
    @options.id = @id = "ql-editor-#{Quill.editors.length + 1}"
    @options.emitter = this
    @modules = {}
    @root = this.addContainer('ql-editor')
    @editor = new Editor(@root, this, @options)
    Quill.editors.push(this)
    this.setHTML(html, Quill.sources.SILENT)
    themeClass = Quill.themes[@options.theme]
    throw new Error("Cannot load #{@options.theme} theme. Are you sure you registered it?") unless themeClass?
    @theme = new themeClass(this, @options)
    _.each(@options.formats, (name) =>
      @editor.doc.addAttribute(name, Quill.formats[name]...)
    )
    _.each(@options.embeds, (name) =>
      @editor.doc.addAttribute(name, Quill.embeds[name]...)
    )
    _.each(@options.modules, (option, name) =>
      this.addModule(name, option)
    )

  destroy: ->
    html = this.getHTML()
    _.each(@modules, (module, name) ->
      module.destroy() if _.isFunction(module.destroy)
    )
    @editor.destroy()
    this.removeAllListeners()
    Quill.editors.splice(_.indexOf(Quill.editors, this), 1)
    @container.innerHTML = html

  addContainer: (className, before = false) ->
    refNode = if before then @root else null
    container = document.createElement('div')
    dom(container).addClass(className)
    @container.insertBefore(container, refNode)
    return container

  addEmbed: (name, embed) ->
    embed = Quill.embeds[name]
    throw new Error("Cannot load #{name} embed. Are you sure you registered it?") unless embed?
    @editor.doc.addEmbed(name, embed)

  addFormat: (name, format) ->
    format = Quill.formats[name]
    throw new Error("Cannot load #{name} format. Are you sure you registered it?") unless format?
    @editor.doc.addFormat(name, format)

  addModule: (name, options) ->
    moduleClass = Quill.modules[name]
    throw new Error("Cannot load #{name} module. Are you sure you registered it?") unless moduleClass?
    options = {} if options == true   # Allow for addModule('module', true)
    options = _.defaults(options, @theme.constructor.OPTIONS[name] or {}, moduleClass.DEFAULTS or {})
    @modules[name] = new moduleClass(this, options)
    this.emit(Quill.events.MODULE_INIT, name, @modules[name])
    return @modules[name]

  deleteText: (start, end, source = Quill.sources.API) ->
    [start, end, formats, source] = this._buildParams(start, end, {}, source)
    return unless end > start
    @editor.deleteAt(start, end, source)

  emit: (eventName, args...) ->
    super(Quill.events.PRE_EVENT, eventName, args...)
    super(eventName, args...)
    super(Quill.events.POST_EVENT, eventName, args...)

  focus: ->
    @editor.focus()

  formatLine: (start, end, name, value, source) ->
    [start, end, formats, source] = this._buildParams(start, end, name, value, source)
    [line, offset] = @editor.doc.findLineAt(end)
    end += (line.length - offset) if line?
    this.formatText(start, end, formats, source)

  formatText: (start, end, name, value, source) ->
    [start, end, formats, source] = this._buildParams(start, end, name, value, source)
    return unless end > start
    @editor.formatAt(start, end, formats, source)

  getBounds: (index) ->
    return @editor.getBounds(index)

  getContents: (start = 0, end = null) ->
    if _.isObject(start)
      end = start.end
      start = start.start
    return @editor.delta.slice(start, end)

  getHTML: ->
    @editor.doc.getHTML()

  getLength: ->
    return @editor.length

  getModule: (name) ->
    return @modules[name]

  getSelection: ->
    @editor.checkUpdate()   # Make sure we access getRange with editor in consistent state
    return @editor.selection.getRange()

  getText: (start = 0, end = null) ->
    return _.map(this.getContents(start, end).ops, (op) ->
      return if _.isString(op.insert) then op.insert else ''
    ).join('')

  insertEmbed: (index, type, value, source) ->
    return unless Quill.embeds[type]?
    attribute = {}
    attribute[type] = value
    @editor.insertAt(index, Quill.embeds[type][0], value, source)

  insertText: (index, text, name, value, source) ->
    [index, end, formats, source] = this._buildParams(index, 0, name, value, source)
    return unless text.length > 0
    @editor.insertAt(index, text, formats, source)

  onModuleLoad: (name, callback) ->
    if (@modules[name]) then return callback(@modules[name])
    this.on(Quill.events.MODULE_INIT, (moduleName, module) ->
      callback(module) if moduleName == name
    )

  prepareFormat: (name, value) ->
    format = @editor.doc.formats[name]
    return unless format?     # TODO warn
    range = this.getSelection()
    return unless range?.isCollapsed()
    if format.type == Formatter.types.LINE
      this.formatLine(range, name, value, Quill.sources.USER)
    else
      Formatter.prepare(format, value)

  setContents: (delta, source = Quill.sources.API) ->
    if Array.isArray(delta)
      delta = { ops: delta.slice() }
    else
      delta = { ops: delta.ops.slice() }
    delta.ops.push({ delete: this.getLength() })
    this.updateContents(delta, source)

  setHTML: (html, source = Quill.sources.API) ->
    html = "<#{dom.DEFAULT_BLOCK_TAG}><#{dom.DEFAULT_BREAK_TAG}></#{dom.DEFAULT_BLOCK_TAG}>" unless html.trim()
    @editor.doc.setHTML(html)
    @editor.checkUpdate(source)

  setSelection: (start, end, source = Quill.sources.API) ->
    if _.isNumber(start) and _.isNumber(end)
      range = new Range(start, end)
    else
      range = start
      source = end or source
    @editor.selection.setRange(range, source)

  setText: (text, source = Quill.sources.API) ->
    delta = new Delta().insert(text)
    this.setContents(delta, source)

  updateContents: (delta, source = Quill.sources.API) ->
    @editor.applyDelta(delta, source)

  # fn(Number start, Number end, String name, String value, String source)
  # fn(Number start, Number end, Object formats, String source)
  # fn(Object range, String name, String value, String source)
  # fn(Object range, Object formats, String source)
  _buildParams: (params...) ->
    if _.isObject(params[0])
      params.splice(0, 1, params[0].start, params[0].end)
    if _.isString(params[2])
      formats = {}
      formats[params[2]] = params[3]
      params.splice(2, 2, formats)
    params[3] ?= Quill.sources.API
    params[0] = Math.min(0, Math.max(this.getLength(), params[0]))
    params[1] = Math.min(params[0], Math.max(this.getLength(), params[1]))
    return params


Quill.registerTheme('base', require('./themes/base'))
Quill.registerTheme('snow', require('./themes/snow'))


module.exports = Quill
