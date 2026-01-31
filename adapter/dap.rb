#!/usr/bin/env ruby # usa o interpretador ruby
# frozen_string_literal: true # congela literais de string

require 'json' # encode/decode JSON
require 'set' # coleção Set
require 'fileutils' # helpers de filesystem

$stdout.sync = true # faz flush imediato no stdout
$stderr.sync = true # faz flush imediato no stderr

log_io = nil # handle do arquivo de log
begin # início da configuração do log
  log_path = ENV['DAP_LOG_PATH'] || File.join(Dir.pwd, '.ruby-dap-logs', 'dap_io.log') # resolve caminho do log
  FileUtils.mkdir_p(File.dirname(log_path)) # garante diretório do log
  log_io = File.open(log_path, 'a') # abre arquivo em append
  log_io.sync = true # flush imediato no arquivo
rescue => e # captura erros de log
  $stderr.puts("DAP LOG ERROR #{e.class}: #{e.message}") # reporta falha de log
end # fim da configuração do log

dap_state = { initialized: false } # estado do DAP (usando hash para ser modificável)

# Versão básica de log_line (será atualizada depois)
log_line = lambda do |line| # helper para logar linha
  timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S.%3N') # timestamp com milissegundos
  formatted_line = "[#{timestamp}] #{line}" # linha formatada com timestamp
  $stderr.puts(formatted_line) # escreve no console debug
  log_io&.puts(formatted_line) # escreve no arquivo se existir
end # fim do helper de log

seq = 1 # contador de sequência de mensagens
buffer = +'' # buffer de entrada do stream

state = { # estado do debugger
  program_path: nil, # caminho do programa atual
  lines: [], # linhas do programa
  current_line: 1, # linha atual
  breakpoints: Hash.new { |h, k| h[k] = Set.new }, # breakpoints por arquivo
  stop_on_entry: true, # parar ao iniciar
  terminated: false # flag de término
} # fim do estado

next_seq = lambda do # gerador de sequência
  current = seq # captura seq atual
  seq += 1 # incrementa seq
  current # retorna seq capturada
end # fim do gerador

send_msg = lambda do |msg| # envia uma mensagem DAP
  json = JSON.generate(msg) # encode em JSON
  header = "Content-Length: #{json.bytesize}\r\n\r\n" # header DAP
  # skip_output_event=true evita recursão infinita (log_line -> send_event -> send_msg -> log_line)
  log_line.call("DAP SAÍDA: #{json}", true) # log apenas do JSON de saída
  $stdout.write(header) # escreve header no stdout
  $stdout.write(json) # escreve body no stdout
end # fim do envio de mensagem

send_response = lambda do |request, body = {}, success = true, message = nil| # envia response
  response = { # monta objeto de response
    type: 'response', # tipo response
    seq: next_seq.call, # sequência do response
    request_seq: request['seq'], # sequência do request
    success: success, # flag de sucesso
    command: request['command'], # comando original
    body: body # corpo do response
  } # fim do response
  response['message'] = message if !success && message # mensagem de erro opcional
  send_msg.call(response) # envia response
end # fim do response

send_event = lambda do |event, body = {}| # envia event
  send_msg.call({ # monta objeto de event
    type: 'event', # tipo event
    seq: next_seq.call, # sequência do event
    event: event, # nome do event
    body: body # corpo do event
  }) # envia event
end # fim do event

# Atualiza log_line para incluir output event no Debug Console
# Usa flag para evitar recursão infinita (não envia output event quando está logando uma mensagem DAP)
log_line = lambda do |line, skip_output_event = false| # helper para logar linha
  timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S.%3N') # timestamp com milissegundos
  formatted_line = "[#{timestamp}] #{line}" # linha formatada com timestamp
  $stderr.puts(formatted_line) # escreve no console debug
  log_io&.puts(formatted_line) # escreve no arquivo se existir
  
  # Envia para Debug Console do VS Code via Output Event
  # skip_output_event evita recursão quando log_line é chamado de dentro de send_msg
  if !skip_output_event && dap_state[:initialized] # só envia se DAP foi inicializado e não está em recursão
    begin # tenta enviar output event
      send_event.call('output', { # evento de output
        category: 'stdout', # categoria stdout
        output: formatted_line + "\n" # mensagem formatada
      }) # fim do output event
    rescue => e # captura erros
      # Ignora erros ao enviar output (pode falhar se DAP não estiver pronto)
    end # fim do rescue
  end # fim do if
end # fim do helper de log

send_stopped = lambda do |reason| # envia stopped
  send_event.call('stopped', { # payload do stopped
    reason: reason, # motivo da parada
    threadId: 1, # id da thread única
    allThreadsStopped: true # todas threads paradas
  }) # fim do payload
end # fim do stopped

send_terminated = lambda do # envia terminated
  return if state[:terminated] # evita duplicar

  state[:terminated] = true # marca como terminado
  send_event.call('terminated', {}) # emite terminated
end # fim do terminated

load_program = lambda do |program_path| # carrega o programa
  content = File.read(program_path) # lê arquivo
  lines = content.split(/\r?\n/) # separa em linhas
  lines = [''] if lines.empty? # garante pelo menos uma linha
  state[:lines] = lines # guarda linhas
  state[:current_line] = 1 # reseta linha atual
end # fim do load_program

breakpoints_for_program = lambda do # obtém breakpoints do programa
  bp = state[:breakpoints][state[:program_path]] # pega set do arquivo atual
  bp ? bp.to_a.sort : [] # retorna lista ordenada
end # fim do breakpoints

find_next_breakpoint = lambda do |start_line| # acha próximo breakpoint
  breakpoints_for_program.call.each do |line| # percorre breakpoints
    return line if line >= start_line # primeiro no/apos start
  end # fim do loop
  nil # nenhum encontrado
end # fim do find_next_breakpoint

continue_execution = lambda do |include_current| # continua execução
  return if state[:program_path].nil? || state[:terminated] # guarda estado inválido

  start = include_current ? state[:current_line] : state[:current_line] + 1 # linha inicial
  next_bp = find_next_breakpoint.call(start) # próximo breakpoint
  if next_bp # se achou
    state[:current_line] = next_bp # move para breakpoint
    send_stopped.call('breakpoint') # emite stopped
    return # encerra
  end # fim do if

  if state[:lines].empty? # se não há linhas
    send_terminated.call # termina sessão
    return # encerra
  end # fim do if empty

  state[:current_line] = state[:lines].length # vai para última linha
  send_terminated.call # termina sessão
end # fim do continue

step_one = lambda do # step de uma linha
  return if state[:program_path].nil? || state[:terminated] # guarda estado inválido

  if state[:current_line] >= state[:lines].length # se está no fim
    send_terminated.call # termina sessão
    return # encerra
  end # fim do if

  state[:current_line] += 1 # avança linha
  send_stopped.call('step') # emite stopped
end # fim do step

handle_request = lambda do |request| # trata request DAP
  case request['command'] # dispatch por comando
  when 'initialize' # initialize
    dap_state[:initialized] = true # marca DAP como inicializado
    send_response.call(request, { # capabilities
      supportsConfigurationDoneRequest: true, # suporta configurationDone
      supportsTerminateRequest: true, # suporta terminate
      supportsSetVariable: false, # não suporta setVariable
      supportsStepBack: false, # não suporta stepBack
      supportsDataBreakpoints: false, # não suporta data breakpoints
      supportsEvaluateForHovers: false # não suporta hover
    }) # envia capabilities
    send_event.call('initialized') # emite initialized
  when 'launch' # launch
    program = request.dig('arguments', 'program') # pega caminho do programa
    unless program # se faltou
      send_response.call(request, {}, false, 'Missing "program" path') # erro
      next # pula
    end # fim do unless

    state[:program_path] = program # grava caminho
    state[:stop_on_entry] = request.dig('arguments', 'stopOnEntry') != false # define stop_on_entry
    state[:terminated] = false # reseta terminated

    begin # tenta carregar
      load_program.call(program) # carrega o programa
    rescue => e # se falhar
      send_response.call(request, {}, false, "Cannot read program: #{e.message}") # erro
      next # pula
    end # fim do rescue

    send_response.call(request, {}) # responde launch
  when 'setBreakpoints' # setBreakpoints
    source = request.dig('arguments', 'source') || {} # pega source
    path_key = source['path'] || state[:program_path] # resolve path
    requested = request.dig('arguments', 'breakpoints') || [] # breakpoints pedidos

    verified = [] # lista verificada
    bp_set = Set.new # set de breakpoints válidos

    requested.each do |bp| # percorre pedidos
      line = bp['line'] # linha do breakpoint
      ok = line.is_a?(Integer) && line >= 1 && line <= state[:lines].length # valida linha
      bp_set.add(line) if ok # adiciona se ok
      verified << { verified: ok, line: line } # adiciona retorno
    end # fim do loop

    state[:breakpoints][path_key] = bp_set if path_key # salva breakpoints
    send_response.call(request, { breakpoints: verified }) # responde
  when 'setExceptionBreakpoints' # setExceptionBreakpoints
    send_response.call(request, {}) # responde vazio
  when 'configurationDone' # configurationDone
    send_response.call(request, {}) # responde
    if state[:stop_on_entry] # se parar na entrada
      send_stopped.call('entry') # emite stopped
    else # senão
      continue_execution.call(true) # continua
    end # fim do if
  when 'threads' # threads
    send_response.call(request, { threads: [{ id: 1, name: 'thread-1' }] }) # thread única
  when 'stackTrace' # stackTrace
    source_path = state[:program_path] || '' # caminho do source
    send_response.call(request, { # responde stack
      stackFrames: [ # frames
        { # frame único
          id: 1, # id do frame
          name: 'main', # nome do frame
          line: state[:current_line], # linha atual
          column: 1, # coluna
          source: { # info do source
            name: source_path.empty? ? 'program' : File.basename(source_path), # nome do source
            path: source_path # caminho do source
          } # fim do source
        } # fim do frame
      ], # fim dos frames
      totalFrames: 1 # total
    }) # responde stack
  when 'scopes' # scopes
    send_response.call(request, { # responde scopes
      scopes: [ # lista
        { name: 'Locals', variablesReference: 1, expensive: false } # locals
      ] # fim da lista
    }) # responde scopes
  when 'variables' # variables
    if request.dig('arguments', 'variablesReference') == 1 # locals
      line_text = state[:lines][state[:current_line] - 1] || '' # texto da linha atual
      send_response.call(request, { # responde variables
        variables: [ # lista
          { name: 'line', value: state[:current_line].to_s, variablesReference: 0 }, # linha
          { name: 'text', value: line_text.inspect, variablesReference: 0 } # texto
        ] # fim da lista
      }) # responde
    else # outro reference
      send_response.call(request, { variables: [] }) # responde vazio
    end # fim do if
  when 'continue' # continue
    send_response.call(request, { allThreadsContinued: true }) # responde
    continue_execution.call(false) # continua
  when 'next', 'stepIn' # next/stepIn
    send_response.call(request, {}) # responde
    step_one.call # step
  when 'stepOut' # stepOut
    send_response.call(request, {}) # responde
    state[:current_line] = state[:lines].length # vai pro fim
    send_terminated.call # termina
  when 'pause' # pause
    send_response.call(request, {}) # responde
    send_stopped.call('pause') # emite stopped
  when 'terminate', 'disconnect' # terminate/disconnect
    send_response.call(request, {}) # responde
    send_terminated.call # termina
  else # comando desconhecido
    send_response.call(request, {}) # resposta default
  end # fim do case
end # fim do handle_request

handle_message = lambda do |msg| # trata mensagem
  return unless msg['type'] == 'request' # ignora não-request

  handle_request.call(msg) # delega request
end # fim do handle_message

parse_buffer = lambda do # faz parse do buffer
  loop do # continua enquanto houver mensagem completa
    header_end = buffer.index("\r\n\r\n") # acha fim do header
    break unless header_end # sai se não há header completo

    header = buffer.byteslice(0, header_end) # extrai header
    match = /Content-Length:\s*(\d+)/i.match(header) # pega content-length
    unless match # se não achou length
      buffer = buffer.byteslice(header_end + 4, buffer.bytesize - header_end - 4) || '' # descarta header
      next # continua
    end # fim do unless

    length = match[1].to_i # tamanho do body
    total = header_end + 4 + length # tamanho total
    break if buffer.bytesize < total # espera mensagem completa

    body = buffer.byteslice(header_end + 4, length) # extrai body
    buffer = buffer.byteslice(total, buffer.bytesize - total) || '' # remove do buffer

    begin # tenta parsear
      msg = JSON.parse(body) # parse JSON
      log_line.call("DAP ENTRADA: #{JSON.generate(msg)}") # log apenas do JSON de entrada
      handle_message.call(msg) # trata mensagem
    rescue JSON::ParserError => e # erro de parse
      log_line.call("ERRO AO PARSEAR JSON: #{e.message}") # log do erro
    end # fim do begin/rescue
  end # fim do loop
end # fim do parse_buffer

begin # início do loop principal
  while (chunk = $stdin.readpartial(8192)) # lê do stdin
    buffer << chunk # adiciona ao buffer
    parse_buffer.call # parseia mensagens
  end # fim do while
rescue EOFError # EOF
  # Exit cleanly
end # fim do loop principal
