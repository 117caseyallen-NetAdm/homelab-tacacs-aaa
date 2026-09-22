# Oxidized model overrides

Two redaction gaps in Oxidized 0.37.0's bundled models, both found by checking
what actually landed in the backup repository rather than trusting the model.

Oxidized loads a model from `~/.config/oxidized/model/` in preference to the
copy inside the gem. Copy the upstream file there, add the one line, and the fix
survives a gem upgrade — the upstream file is replaced on every upgrade.

```bash
cp /var/lib/gems/*/gems/oxidized-*/lib/oxidized/model/eos.rb   ~oxidized/.config/oxidized/model/
cp /var/lib/gems/*/gems/oxidized-*/lib/oxidized/model/panos.rb ~oxidized/.config/oxidized/model/
```

## `eos.rb` — the TACACS+ key was published unredacted

The `eos` model only strips the form anchored on the encryption digit
(`tacacs-server key 7 …`). The Arista's key is on the host line
(`tacacs-server host 10.99.20.32 key 7 …`), which that pattern does not match,
so the key reached the backup repository.

The `ios` model has had the general form all along:

```ruby
# oxidized/model/ios.rb, upstream
cfg.gsub! /^(.*key 7) (\d.+)/,              '\\1 <secret hidden>'   # narrow
cfg.gsub! /^(tacacs-server (.+ )?key) .+/, '\\1 <secret hidden>'   # general
```

The fix is to add ios.rb's general line to eos.rb's `:secret` block:

```ruby
cfg.gsub! /^(tacacs-server key \d+).*/, '\\1 <configuration removed>'   # upstream
cfg.gsub! /^(tacacs-server (.+ )?key) .+/, '\\1 <secret hidden>'       # OVERRIDE
```

`(.+ )?` absorbs `host 10.99.20.32 `; `.+` takes everything after `key`,
encrypted or bare.

## `panos.rb` — the chassis serial was in every backup

The `panos` model strips eight fields from `show system info` — uptime, and the
`app-`, `av-`, `threat-`, `wildfire-`, `wf-private`, `device-dictionary-`,
`url-filtering` and `global-` version lines — and leaves `serial:`, the one
durable hardware identifier. Add to the `show system info` block, before
`comment cfg`:

```ruby
cfg.gsub! /^serial: .*$/, 'serial: <redacted>'   # OVERRIDE
```

## Not a redaction issue, but the same device: the timeout

The `panos` model runs `show config running`, which on PAN-OS 10.2 includes the
entire predefined App-ID catalogue — about 70,000 lines. The job takes 39 to 50
seconds. The global `timeout:` was 30. The backup failed with
`Timeout::Error: execution expired`, retried, gave up, and reported nothing:
the git history still looked healthy, just stale.

It was failing by nine seconds or more. Earlier backups had succeeded, and what
tipped it over isn't established. It wasn't a content update: this PA-440 is
unlicensed and can't download them. `timeout: 600` fixed it as a stopgap; the proper fix is a scoped
collection command that backs up the local config instead of the vendor's
application catalogue.

(The config also has a `timeout:` nested under `hooks:` — that one governs the
git push, not SSH.)
