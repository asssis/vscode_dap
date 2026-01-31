# Como funciona o Toy DAP (Ruby)

Este projeto implementa um **debug adapter mínimo** em Ruby para demonstrar o Debug Adapter Protocol (DAP).
Ele **não executa** o código Ruby de verdade; apenas **simula o avanço de linhas** e reporta isso ao VS Code.

## Visão geral do fluxo

1. O VS Code lê o `package.json` e registra o debug type `toy-ruby`.
2. Ao iniciar o debug, o VS Code executa `adapter/dap.rb` com o runtime `ruby`.
3. O adapter fala DAP via **stdin/stdout**, usando `Content-Length` + JSON.
4. O `launch` carrega o arquivo (`program`) e prepara as linhas.
5. O VS Code pede `stackTrace`, `scopes` e `variables` e usa essas respostas para
   **destacar a linha atual** no editor.

## Protocolo DAP (como o adapter fala)

- **Mensagens**: JSON com cabeçalho `Content-Length`.
- **Requests** do VS Code → **responses** do adapter.
- **Events** (como `stopped` e `terminated`) são emitidos pelo adapter.
- O parser em `adapter/dap.rb` acumula chunks, extrai `Content-Length` e decodifica JSON.

## Estado interno (adapter/dap.rb)

O adapter guarda um estado simples:

- `program_path`: caminho do arquivo em debug
- `lines`: array com as linhas do arquivo
- `current_line`: linha atual (1-based)
- `breakpoints`: mapa de arquivo → conjunto de linhas
- `stop_on_entry`: controla se para logo na entrada
- `terminated`: evita emitir `terminated` duas vezes

## Breakpoints e stepping

- `setBreakpoints` valida linhas (1..n) e salva no `breakpoints`.
- `continue` procura o **próximo breakpoint** a partir da linha atual.
  - Se encontrar, emite `stopped` com razão `breakpoint`.
  - Se não encontrar, vai para o fim e emite `terminated`.
- `next` e `stepIn` avançam **uma linha** e emitem `stopped` com razão `step`.
- `stepOut` pula direto para o fim e termina.

## Stack, scopes e variáveis

O adapter fornece um **stack trace fake** com um único frame:

- `stackTrace` retorna um frame `main` com a `current_line`.
- `scopes` retorna `Locals` com `variablesReference: 1`.
- `variables` retorna duas “variáveis”:
  - `line`: número da linha atual
  - `text`: conteúdo da linha atual

Isso é suficiente para o VS Code mostrar o highlight da linha.

## Limitações intencionais

- Não executa o Ruby real (apenas simula linhas).
- Sem avaliação de expressões.
- Sem exceções reais.
- Apenas uma thread (`id: 1`).

## Onde mexer

- `adapter/dap.rb`: lógica do adapter e parsing do DAP.
- `example/program.rb`: arquivo Ruby de exemplo.
- `example/.vscode/launch.json`: configuração de debug.
- `package.json`: registro do debug type `toy-ruby`.
