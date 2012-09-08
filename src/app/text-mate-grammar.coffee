_ = require 'underscore'
fs = require 'fs'
plist = require 'plist'

module.exports =
class TextMateGrammar
  @loadFromPath: (path) ->
    grammar = null
    plist.parseString fs.read(path), (e, data) ->
      throw new Error(e) if e
      grammar = new TextMateGrammar(data[0])
    grammar

  name: null
  fileTypes: null
  foldEndRegex: null
  repository: null
  initialRule: null

  constructor: ({ @name, @fileTypes, scopeName, patterns, repository, foldingStopMarker}) ->
    @initialRule = new Rule(this, {scopeName, patterns})
    @repository = {}
    @foldEndRegex = new OnigRegExp(foldingStopMarker) if foldingStopMarker

    for name, data of repository
      @repository[name] = new Rule(this, data)

  getLineTokens: (line, stack=[@initialRule]) ->
    stack = new Array(stack...)
    tokens = []
    position = 0

    loop
      scopes = scopesFromStack(stack)

      if line.length == 0
        tokens = [{value: "", scopes: scopes}]
        return { tokens, scopes }

      break if position == line.length

      { nextTokens, tokensStartPosition, tokensEndPosition} = _.last(stack).getNextTokens(stack, line, position)

      if nextTokens
        if position < tokensStartPosition # unmatched text preceding next tokens
          tokens.push
            value: line[position...tokensStartPosition]
            scopes: scopes

        tokens.push(nextTokens...)
        position = tokensEndPosition
      else if tokensEndPosition - tokensStartPosition != 0 # break unless it was a zero length match
        tokens.push
          value: line[position...line.length]
          scopes: scopes
        break

    { tokens, stack }

  ruleForInclude: (name) ->
    if name[0] == "#"
      @repository[name[1..]]
    else if name == "$self"
      @initialRule

class Rule
  grammar: null
  scopeName: null
  patterns: null
  createEndPattern: null

  constructor: (@grammar, {@scopeName, patterns, @createEndPattern}) ->
    patterns ?= []
    @patterns = []
    @patterns.push((patterns.map (pattern) => new Pattern(grammar, pattern))...)

  getIncludedPatterns: (included=[]) ->
    return [] if _.include(included, this)
    included.push(this)
    allPatterns = []

    for pattern in @patterns
      allPatterns.push(pattern.getIncludedPatterns(included)...)
    allPatterns

  getNextTokens: (stack, line, position) ->
    patterns = @getIncludedPatterns()
    {index, captureIndices} = OnigRegExp.captureIndices(line, position, patterns.map (p) -> p.regex )

    return {} unless index?

    [firstCaptureIndex, firstCaptureStart, firstCaptureEnd] = captureIndices
    nextTokens = patterns[index].handleMatch(stack, line, captureIndices)
    { nextTokens, tokensStartPosition: firstCaptureStart, tokensEndPosition: firstCaptureEnd }

  getNextMatch: (line, position) ->
    nextMatch = null
    matchedPattern = null

    for pattern in @patterns
      { pattern, match } = pattern.getNextMatch(line, position)
      if match
        if !nextMatch or match.position < nextMatch.position
          nextMatch = match
          matchedPattern = pattern

    { match: nextMatch, pattern: matchedPattern }

  addEndPattern: (backReferences) ->
    endPattern = @createEndPattern(backReferences)
    @patterns.unshift(endPattern)

  removeEndPattern: ->
    @patterns.shift()

class Pattern
  grammar: null
  pushRule: null
  popRule: false
  scopeName: null
  regex: null
  captures: null
  backReferences: null

  constructor: (@grammar, { name, contentName, @include, match, begin, end, captures, beginCaptures, endCaptures, patterns, @popRule}) ->
    @scopeName = name ? contentName # TODO: We need special treatment of contentName
    if match
      @regex = new OnigRegExp(match)
      @captures = captures
    else if begin
      @regex = new OnigRegExp(begin)
      @captures = beginCaptures ? captures
      createEndPattern = (backReferences) ->
        end = end.replace /(\\\d+)/g, (match) ->
          index = parseInt(match[1..])
          _.escapeRegExp(backReferences[index] ? "\\#{index}")
        new Pattern(@grammar, { match: end, captures: endCaptures ? captures, popRule: true})
      @pushRule = new Rule(@grammar, { @scopeName, patterns, createEndPattern })

  getIncludedPatterns: (included) ->
    if @include
      rule = @grammar.ruleForInclude(@include)
      # console.log "Could not find rule for include #{@include} in #{@grammar.name} grammar" unless rule
      rule?.getIncludedPatterns(included) ? []
    else
      [this]

  getNextMatch: (line, position) ->
    if @include
      rule = @grammar.ruleForInclude(@include)
      rule.getNextMatch(line, position)
    else
      { match: @regex.getCaptureIndices(line, position), pattern: this }

  handleMatch: (stack, line, captureIndices) ->
    scopes = scopesFromStack(stack)
    scopes.push(@scopeName) if @scopeName and not @popRule

    if @captures
      tokens = @getTokensForCaptureIndices(line, _.clone(captureIndices), scopes)
    else
      [start, end] = captureIndices[1..2]
      zeroLengthMatch = end == start
      if zeroLengthMatch
        tokens = null
      else
        tokens = [{ value: line[start...end], scopes: scopes }]

    if @pushRule
      @pushRule.addEndPattern(@backreferencesForCaptureIndices(line, captureIndices))
      stack.push(@pushRule)
    else if @popRule
      rule = stack.pop()
      rule.removeEndPattern()

    tokens

  backreferencesForCaptureIndices: (line, captureIndices) ->
    backReferences = []
    for i in [0...captureIndices.length] by 3
      start = captureIndices[i + 1]
      end = captureIndices[i + 2]
      backReferences.push line[start...end]

    backReferences

  getTokensForCaptureIndices: (line, captureIndices, scopes) ->
    [parentCaptureIndex, parentCaptureStart, parentCaptureEnd] = shiftCapture(captureIndices)

    tokens = []
    if scope = @captures[parentCaptureIndex]?.name
      scopes = scopes.concat(scope)

    previousChildCaptureEnd = parentCaptureStart
    while captureIndices.length and captureIndices[1] < parentCaptureEnd
      [childCaptureIndex, childCaptureStart, childCaptureEnd] = captureIndices

      emptyCapture = childCaptureEnd - childCaptureStart == 0
      captureHasNoScope = not @captures[childCaptureIndex]
      if emptyCapture or captureHasNoScope
        shiftCapture(captureIndices)
        continue

      if childCaptureStart > previousChildCaptureEnd
        tokens.push
          value: line[previousChildCaptureEnd...childCaptureStart]
          scopes: scopes

      captureTokens = @getTokensForCaptureIndices(line, captureIndices, scopes)
      tokens.push(captureTokens...)
      previousChildCaptureEnd = childCaptureEnd

    if parentCaptureEnd > previousChildCaptureEnd
      tokens.push
        value: line[previousChildCaptureEnd...parentCaptureEnd]
        scopes: scopes

    tokens

shiftCapture = (captureIndices) ->
  [captureIndices.shift(), captureIndices.shift(), captureIndices.shift()]

scopesFromStack = (stack) ->
  _.compact(_.pluck(stack, "scopeName"))

