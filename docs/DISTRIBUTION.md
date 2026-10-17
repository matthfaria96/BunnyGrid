# Distribuição do BunnyGrid (fora da Mac App Store)

Este guia leva o BunnyGrid de `swift build` até um DMG assinado, notarizado e com atualização automática.
Tudo o que depende da conta Apple Developer vem de variáveis de ambiente ou de `scripts/release.env`
(ignorado pelo git). Sem conta, os mesmos scripts geram um app e um DMG com assinatura **ad hoc**: servem
para testar, mas o Gatekeeper bloqueia cópias baixadas da internet.

## Resumo: o que já funciona e o que depende da conta

| Item | Sem conta (ad hoc) | Com Developer ID |
| --- | --- | --- |
| Build release universal (arm64 + x86_64), ícone compilado, Info.plist com versão do git | ✅ | ✅ |
| Hardened Runtime + entitlements, assinatura de dentro para fora (Sparkle, depois o app), `codesign --verify --strict` | ✅ (ad hoc) | ✅ |
| DMG com fundo, atalho para Applications, posições dos ícones e ícone do volume | ✅ | ✅ (DMG também assinado) |
| `--run-job` (jobs agendados pelo launchd) no binário release | ✅ | ✅ |
| Sparkle embutido e inerte; "Check for Updates…" quando o feed é configurado; `appcast.sh` | ✅ (testado com chave descartável) | ✅ |
| Gatekeeper (`spctl -a`) aceita o app e o DMG baixados | ❌ "rejected" (esperado) | ✅ depois de `--notarize` |
| Notarização + `stapler staple` (app e DMG) | ❌ (o script avisa e para) | ✅ |
| Keychain sem pedir senha a cada build novo | ❌ (ver [Keychain](#keychain)) | ✅ |

## 1. Certificado Developer ID (uma vez)

1. Entre no programa Apple Developer (conta paga, individual ou de empresa).
2. No Xcode: **Settings › Accounts**, adicione o Apple ID, selecione o time e clique em **Manage Certificates…**
   › **+** › **Developer ID Application**. (Ou em developer.apple.com › Certificates › **+** ›
   *Developer ID Application*, com um CSR criado no Acesso às Chaves, e dê dois cliques no `.cer` baixado.)
3. Confira que o certificado e a chave privada estão no Keychain:

   ```sh
   security find-identity -v -p codesigning
   # 1) ABCDEF0123… "Developer ID Application: Seu Nome (ABCDE12345)"
   ```

   O texto entre aspas (ou o hash) é o `BUNNYGRID_SIGN_IDENTITY`; `ABCDE12345` é o seu Team ID.
4. Faça backup do certificado **com a chave privada** (Acesso às Chaves › exportar `.p12`). Sem a chave não
   dá para assinar versões novas com a mesma identidade.

## 2. Credenciais de notarização (uma vez)

Crie uma senha de app em [account.apple.com](https://account.apple.com) › Login e Segurança › Senhas de App, e
guarde as credenciais num perfil do Keychain (o `notarytool` nunca lê a senha de arquivos do projeto):

```sh
xcrun notarytool store-credentials "bunnygrid-notary" \
  --apple-id voce@exemplo.com --team-id ABCDE12345 --password <senha-de-app>
```

Alternativa com chave da App Store Connect API: `--key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>`.

## 3. Configuração do projeto

```sh
cp scripts/release.env.example scripts/release.env
```

e preencha (o que já estiver exportado no shell tem prioridade sobre o arquivo):

| Variável | Para quê |
| --- | --- |
| `BUNNYGRID_SIGN_IDENTITY` | `Developer ID Application: Seu Nome (ABCDE12345)`; vazio ou `-` = ad hoc |
| `BUNNYGRID_NOTARY_PROFILE` | `bunnygrid-notary` (o nome usado no passo 2) |
| `BUNNYGRID_SPARKLE_FEED_URL` | URL **https** do `appcast.xml` (ex.: `https://bunnygrid.app/updates/appcast.xml`) |
| `BUNNYGRID_SPARKLE_PUBLIC_KEY` | chave pública EdDSA (passo 4) |
| `BUNNYGRID_SPARKLE_DOWNLOAD_PREFIX` | opcional: onde ficam os DMGs, se não for a mesma pasta do appcast |
| `BUNNYGRID_SPARKLE_PRIVATE_KEY_FILE` | opcional (CI): arquivo com a chave privada, em vez do Keychain |
| `BUNNYGRID_COPYRIGHT` | opcional: texto do `NSHumanReadableCopyright` |
| `BUNNYGRID_DIST_DIR`, `BUNNYGRID_BUILD_DIR` | opcional: saída (`dist/`) e pasta do build release (`.build-release/`) |

## 4. Chaves do Sparkle (uma vez, se quiser atualização automática)

```sh
scripts/appcast.sh --generate-keys
```

Cria o par EdDSA (a privada fica no **seu** Keychain, item "Private key for signing Sparkle updates") e mostra a
pública: copie para `BUNNYGRID_SPARKLE_PUBLIC_KEY`. Faça backup da privada
(`.build-release/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt`) num cofre: perdê-la
significa que os apps já instalados não aceitam mais nenhuma atualização. Nunca coloque essa chave no git.

Sem `BUNNYGRID_SPARKLE_FEED_URL` **e** `BUNNYGRID_SPARKLE_PUBLIC_KEY`, o Info.plist sai sem `SUFeedURL`/`SUPublicEDKey`,
o app não cria o atualizador (não acessa a rede) e o menu não mostra "Check for Updates…".

## 5. Gerar uma versão

```sh
git tag v1.0.0                      # a versão vem da última tag vX.Y.Z (ou use --version 1.0.0)
scripts/release.sh --notarize       # build, assinatura, notarização + staple do app, DMG, notarização + staple do DMG
```

Saída em `dist/`: `BunnyGrid.app`, `BunnyGrid-1.0.0.dmg` (com o SHA-256 impresso no fim) e `BunnyGrid.app.dSYM`
(guarde para simbolizar relatórios de crash). O script:

- compila universal (`--arch arm64 --arch x86_64`); se alguma dependência falhar em x86_64, cai para arm64 e
  mostra o erro (`--arch arm64` força só Apple Silicon);
- `CFBundleShortVersionString` = tag ou `--version`; `CFBundleVersion` = número de commits (`git rev-list --count HEAD`),
  sempre crescente, que é o que o Sparkle compara; o commit vai em `BunnyGridCommit`;
- assina de dentro para fora sem `--deep`: `Sparkle.framework/…/Autoupdate`, `Updater.app`, o framework e por
  fim o app com `Resources/BunnyGrid.entitlements`, todos com Hardened Runtime e timestamp seguro;
- confere com `codesign --verify --strict` e `spctl -a -vv`;
- com `--notarize`, para logo no começo (antes de compilar) se faltar identidade ou perfil, com a instrução do que criar.

Sem conta (ou sem `--notarize`) basta `scripts/release.sh`: sai tudo assinado ad hoc e o `spctl` mostra
`rejected` (esperado).

Para conferir à mão:

```sh
codesign --verify --strict --deep --verbose=2 dist/BunnyGrid.app
spctl -a -t exec -vv dist/BunnyGrid.app                    # "accepted  source=Notarized Developer ID"
spctl -a -t open --context context:primary-signature -vv dist/BunnyGrid-1.0.0.dmg
xcrun stapler validate dist/BunnyGrid-1.0.0.dmg
```

## 6. Publicar

1. Suba o DMG para onde ele será baixado (site, GitHub Releases, S3…).
2. Atualização automática: mantenha **todos** os DMGs publicados numa pasta (ex.: `dist/updates/`), opcionalmente
   com as notas `BunnyGrid-1.0.0.html` ao lado, e gere o feed:

   ```sh
   mkdir -p dist/updates && cp dist/BunnyGrid-1.0.0.dmg dist/updates/
   scripts/appcast.sh dist/updates
   ```

   O `generate_appcast` do próprio Sparkle assina cada DMG com a chave privada (`sparkle:edSignature`) e escreve
   `dist/updates/appcast.xml`. Suba o `appcast.xml` para a URL de `BUNNYGRID_SPARKLE_FEED_URL` e os DMGs para a
   mesma pasta (ou para `BUNNYGRID_SPARKLE_DOWNLOAD_PREFIX`). Se o item do appcast sair sem `sparkle:edSignature`, o
   app daquele DMG foi gerado sem `BUNNYGRID_SPARKLE_PUBLIC_KEY`.
3. Os apps instalados checam o feed sozinhos (uma vez por dia, depois de pedir permissão na segunda abertura) e em
   **BunnyGrid › Check for Updates…**.

## Por que sem App Sandbox

O app é assinado com Hardened Runtime, mas **não** é sandboxed. Recursos que deixariam de funcionar:

- **Automação agendada**: grava launch agents em `~/Library/LaunchAgents` e chama `launchctl bootstrap`; o
  sandbox não permite nenhum dos dois (exigiria um helper com `SMAppService` e outra arquitetura).
- **SQLite em qualquer lugar**: além do arquivo escolhido, o SQLite cria `-wal`, `-shm` e `-journal` ao lado; no
  sandbox isso precisa de "related items" declarados por extensão, e as abas restauradas e as consultas salvas
  precisariam de bookmarks com escopo de segurança para cada arquivo.
- **Túnel SSH**: lê chaves privadas e `known_hosts` em `~/.ssh` (caminhos digitados, não escolhidos num painel).
- **Sockets Unix**: PostgreSQL, MySQL e Redis locais em `/tmp` e `/var/run`.
- **Exportações e backups agendados**: escrevem em pastas lembradas entre execuções, inclusive pelo `--run-job`
  iniciado pelo launchd, sem nenhum painel aberto.

Os entitlements `network.client` e `files.user-selected.read-write` estão no arquivo só para documentar a
intenção; fora do sandbox eles não têm efeito. Não há exceções do Hardened Runtime (sem JIT, sem memória
executável sem assinatura, validação de bibliotecas ligada: o Sparkle é assinado com a mesma identidade).

O Info.plist traz textos de uso para Rede Local (macOS 15+, servidores na LAN) e para as pastas protegidas
(Documentos, Mesa, Downloads, volumes removíveis e de rede), que aparecem quando o macOS pede permissão.

## Keychain

As senhas ficam no Keychain de login (`kSecClassGenericPassword`, serviço `app.bunnygrid.connections`). Nesse
Keychain quem decide o acesso é a ACL de cada item, que guarda o *designated requirement* (DR) do app que o criou:

- **Ad hoc** (`build/BunnyGrid.app`, `scripts/bundle.sh`, `release.sh` sem identidade): o DR é o hash do
  binário (`cdhash H"…"`). Cada build novo tem outro hash, então o macOS pergunta de novo
  "BunnyGrid quer usar informações confidenciais armazenadas em …" para cada item, e "Sempre Permitir" vale só
  para aquele build.
- **Developer ID**: o DR é `identifier "app.bunnygrid.BunnyGrid" and anchor apple generic and … certificate
  leaf[subject.OU] = ABCDE12345`. Ele não muda entre versões nem com certificados renovados do mesmo time, então
  todas as versões futuras assinadas pelo mesmo Team ID (e o mesmo bundle id) leem os itens sem perguntar.

Não é preciso `keychain-access-groups`: esse entitlement é do Keychain de proteção de dados (iCloud/iOS) e, num app
Developer ID, exigiria um perfil de provisionamento embutido.

**Migração (uma vez por usuário)**: os itens gravados por um build ad hoc continuam na ACL antiga. Na primeira vez
que a versão Developer ID abrir cada conexão, o macOS pede a senha de login para aquele item; clicando em
**Sempre Permitir**, o DR do Developer ID entra na ACL e o pedido não volta (nem nas próximas versões). São até
três pedidos por conexão (senha do banco, segredo SSH, senha da chave SSL), e só quando aquela conexão é aberta.
Quem preferir pode apagar os itens antigos (Acesso às Chaves, busca por `app.bunnygrid.connections`) e digitar as
senhas de novo no editor de conexão. Itens criados pela versão Developer ID nunca pedem.

As preferências (`app.bunnygrid.BunnyGrid`) e a pasta de dados continuam as mesmas: conexões, consultas e jobs
seguem para a versão assinada. Os launch agents dos jobs agendados guardam o caminho do executável que os
gravou (ex.: `build/BunnyGrid.app`); depois de instalar em `/Applications`, salve de novo cada job agendado na aba
Automation (ou desligue e ligue o agendamento) para apontá-los para o app instalado. Atualizações pelo Sparkle
substituem o app no mesmo lugar, então não mudam o caminho.

## Checklist

Pronto (sem conta):
- [x] `scripts/release.sh` (universal, ícone, versão do git, Info.plist completo, Hardened Runtime, entitlements, verificação)
- [x] `scripts/make-dmg.sh` (fundo próprio, atalho Applications, layout via `.DS_Store` gerado por `scripts/dmg/dmgtool.swift`, sem AppleScript)
- [x] Sparkle 2 via SwiftPM, inerte sem feed; `scripts/appcast.sh` (`--generate-keys` e geração do appcast)
- [x] `--run-job` testado no binário release (arm64 e x86_64 via Rosetta)
- [x] Notarização implementada (`notarytool submit --wait` + `stapler staple` no app e no DMG)

Precisa da conta:
- [ ] Certificado Developer ID Application no Keychain → `BUNNYGRID_SIGN_IDENTITY`
- [ ] `xcrun notarytool store-credentials bunnygrid-notary …` → `BUNNYGRID_NOTARY_PROFILE`
- [ ] `scripts/release.sh --notarize` e conferir `spctl` "accepted source=Notarized Developer ID"
- [ ] Hospedagem https para `appcast.xml` e DMGs; `scripts/appcast.sh --generate-keys`; publicar
- [ ] Testar uma atualização real: instalar a versão N, publicar N+1 e usar Check for Updates…
