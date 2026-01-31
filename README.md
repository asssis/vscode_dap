# DAP (Ruby puro)

Este projeto é um debug adapter mínimo escrito **100% em Ruby** para entender o Debug Adapter Protocol (DAP).
Ele simula um programa linha a linha para permitir usar **F10**, **F11** e ver o **highlight** da linha atual no VS Code.

## Como rodar

1. Abra esta pasta no VS Code.
2. Pressione **F5** para rodar a extensão (`Run Extension (Toy DAP)`).
3. Na nova janela (Extension Development Host), abra `program.rb`.
4. Inicie o debug com a configuração **Toy Ruby Debug**.
5. Use:
   - **F10** (Step Over)
   - **F11** (Step Into)
   - **Shift+F11** (Step Out)

O highlight vai avançar linha a linha no arquivo `.rb`.

## Comunicação stdin/stdout (DAP)

O VS Code inicia o adapter Ruby e conversa com ele via **stdin/stdout**:

- **stdin**: o VS Code envia requests DAP como JSON com header `Content-Length`.
- **stdout**: o adapter responde com `response` e emite `event` (ex.: `stopped`, `terminated`).

No `adapter/dap.rb`, o parser acumula chunks, lê o `Content-Length`, extrai o JSON e processa cada request.

## Arquivos importantes

- `adapter/dap.rb`: o debug adapter Ruby (DAP via stdin/stdout)
- `example/program.rb`: arquivo de exemplo para depurar
- `example/.vscode/launch.json`: configuração de debug
- `package.json`: registra o tipo de debug `toy-ruby`

## O que este adapter suporta

- `initialize`, `launch`, `setBreakpoints`, `configurationDone`
- `threads`, `stackTrace`, `scopes`, `variables`
- `continue`, `next` (F10), `stepIn` (F11), `stepOut`
- `pause`, `terminate`, `disconnect`

Sem dependências externas.

## Exemplo de troca de mensagem

Abaixo tem um exemplo da comunicação entre o stdin e stdout, é através dessa comunicação que é possivel integrar
o visual code com o DAP, abaixo tempo um exemplo do stepIn, variables e outros eventos...

- [2026-01-31 09:59:58.927] DAP ENTRADA: {"command":"stepIn","arguments":{"threadId":1},"type":"request","seq":10}
- [2026-01-31 09:59:58.934] DAP ENTRADA: {"command":"threads","type":"request","seq":11}
- [2026-01-31 09:59:58.944] DAP ENTRADA: {"command":"stackTrace","arguments":{"threadId":1,"startFrame":0,"levels":20},"type":"request",- "seq":12}
- [2026-01-31 09:59:59.359] DAP ENTRADA: {"command":"scopes","arguments":{"frameId":1},"type":"request","seq":13}
- [2026-01-31 09:59:59.362] DAP ENTRADA: {"command":"variables","arguments":{"variablesReference":1},"type":"request","seq":14}




<img width="1171" height="196" alt="Captura de tela de 2026-01-31 10-13-48" src="https://github.com/user-attachments/assets/88ff7bc7-7633-409c-b762-2af40573abd1" />
