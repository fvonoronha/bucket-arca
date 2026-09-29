# Segurança

O bucket-arca guarda cópias dos arquivos de uma aplicação, então segurança é prioridade.

## Como relatar uma falha

**Não abra uma issue pública.** Use o [relato privado de vulnerabilidades do GitHub](../../security/advisories/new) (aba *Security* → *Report a vulnerability*). Responderemos o mais rápido possível e combinaremos a correção e a divulgação.

## Boas práticas ao usar

- Na origem, use uma credencial **só de leitura** (R2: token *Object Read only*).
- No destino, uma credencial **só para o backup**, que só pode apagar em `atual/`; histórico e snapshots saem por regra do bucket (veja o README).
- Ligue a criptografia do snapshot (`BACKUP_ENCRYPTION_RECIPIENTS`) e guarde a **chave privada fora do servidor**.
- Deixe o bucket de destino privado.
- Rode `arca verify` de tempos em tempos: backup que nunca foi conferido não é backup.
