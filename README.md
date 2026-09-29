# chatwoot-fork-ci

Pipeline que gera uma imagem **Chatwoot Community Edition** com os nossos patches,
sem precisar buildar nada na VPS.

A ideia: em vez de manter um fork do Chatwoot rebaseado, este repositório guarda
**apenas os patches**. O GitHub Actions clona o Chatwoot oficial na **tag de release**,
aplica os patches, monta a imagem e publica no GHCR. A VPS só faz `pull`.

```
chatwoot/chatwoot @ v4.18.0   (oficial, tag)
        +
  patches/*.patch             (nosso)
        ↓  GitHub Actions
ghcr.io/<owner>/chatwoot:v4.18.0-fp
        ↓  docker compose pull
      VPS
```

## Estrutura

```
.github/workflows/build.yml   pipeline de build
patches/                      nossos patches (vazio no começo, de propósito)
deploy/atualizar.sh           script para rodar na VPS
```

## Passo a passo

### 1. Criar o repositório

Crie um repositório **privado** no GitHub (os patches contêm regra de negócio nossa).

> Por que privado: o repositório é o único lugar com a nossa lógica.
> Minutos do Actions no repo privado: 2.000/mês grátis no Linux — um build leva
> ~20-40 min, então sobra folga de sobra.

### 2. Subir estes arquivos

```bash
git init
git add .
git commit -m "pipeline inicial"
git branch -M main
git remote add origin git@github.com:<owner>/<repo>.git
git push -u origin main
```

### 3. Primeiro build — SEM patch

**Faça isso antes de qualquer patch.** Assim você valida a pipeline inteira
(registry, permissões, cache, login) e, se algo quebrar, você já sabe que não foi o patch.

Actions → *Build Chatwoot FP (CE + patches)* → **Run workflow**

| Campo | Valor |
|---|---|
| `chatwoot_ref` | `v4.18.0` |
| `tag_suffix` | `fp` |

Ao final, a imagem estará em:
```
ghcr.io/<owner>/chatwoot:v4.18.0-fp
ghcr.io/<owner>/chatwoot:latest-fp
```

### 4. Tornar o pacote acessível para a VPS

O pacote nasce **privado**. Para a VPS conseguir puxar:

Opção A (recomendada) — GitHub → *Packages* → o pacote → *Package settings* →
*Manage Actions access*, ou deixe privado e autentique na VPS (passo 5).

Opção B — marcar o pacote como público (qualquer um baixa, mas **não contém nossos
patches**, apenas o Chatwoot CE compilado — o patch já virou código, então isso é
equivalente a baixar o Chatwoot oficial).

### 5. Autenticar na VPS

Crie um **Personal Access Token (classic)** com escopo **`read:packages`** apenas.

```bash
echo "<TOKEN>" | docker login ghcr.io -u <usuario-github> --password-stdin
```

O login fica salvo em `/root/.docker/config.json` — não precisa repetir.

### 6. Trocar a imagem no compose

Projeto `chatwoot` em `/docker/chatwoot/docker-compose.yml`:

```yaml
  rails:
    image: ghcr.io/<owner>/chatwoot:latest-fp    # era: chatwoot/chatwoot:latest
  sidekiq:
    image: ghcr.io/<owner>/chatwoot:latest-fp
```

Depois:

```bash
cd /docker/chatwoot
docker compose pull
docker compose up -d
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose ps
```

> **Sempre** rode `db:chatwoot_prepare` depois de trocar de versão — é o passo que
> aplica as migrations (o entrypoint do Chatwoot **não** faz isso, descobrimos isso
> na instalação).

### 7. Só então: adicionar patch

Para gerar um patch a partir de uma modificação:

```bash
# 1. clone o Chatwoot na mesma tag
git clone --depth 1 --branch v4.18.0 https://github.com/chatwoot/chatwoot.git /tmp/cw
# 2. faça as alterações em /tmp/cw
# 3. gere o patch
cd /tmp/cw
git diff > /caminho/para/chatwoot-fork-ci/patches/001-minha-mudanca.patch
```

Subir o `.patch` e rodar o workflow de novo. Se o patch não aplicar na tag nova,
o erro é explícito (`git apply --verbose` mostra exatamente o hunk que falhou).

## Atualizar para uma nova versão do Chatwoot

1. Confira a nova tag em https://github.com/chatwoot/chatwoot/releases
2. Rode o workflow com `chatwoot_ref` = a nova tag
3. Se o patch falhar, ajuste o patch (não a árvore do Chatwoot)
4. Na VPS: `docker compose pull && docker compose up -d && db:chatwoot_prepare`

**Sempre com snapshot da Hostinger antes.** E saiba: você está em `latest-fp`, então
a troca de versão só acontece quando você rodar o workflow — não vem sozinha. Isso é
proposital: em produção com agentes atendendo, upgrade silencioso é risco, não conforto.

## Limitações que valem lembrar

- **Não libera features enterprise.** O build CE remove o código enterprise de
  propósito. `sla`, `advanced_search`, `companies` e o painel de campanha continuam
  exigindo licença comercial. Isso não é obstáculo técnico, é licença.
- **O patch compete com as mudanças deles.** Se o Chatwoot reescrever um componente
  que você tocou, seu patch vai falhar no próximo build. É esperado e é por isso que
  mantemos o patch pequeno.
- **A imagem não contém os patches como arquivo** — eles já estão compilados no código.
  Por isso o repositório precisa ser privado, mas o pacote pode ser público.

## Checklist de primeira execução

- [ ] Repositório privado criado
- [ ] Workflow e README commitados
- [ ] Build rodado **sem patch** e concluído
- [ ] Pacote visível em GitHub → Packages
- [ ] PAT `read:packages` criado
- [ ] `docker login ghcr.io` na VPS OK
- [ ] Compose apontando para a imagem nova
- [ ] `db:chatwoot_prepare` rodado
- [ ] Chatwoot respondendo em `chat.franferreira.cloud/health`
- [ ] WhatsApp oficial enviando e recebendo
- [ ] **Só depois disso**: primeiro patch
