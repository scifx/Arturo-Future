# `cd` and a writable `env`

Two additions to the **System** module:

- `cd` — change the current working directory.
- `env` — now a *live, writable* view of the process environment.

---

## `cd`

```arturo
cd "Documents"          ; relative
cd "/tmp"               ; absolute
```

Signature: `cd :string -> :nothing`

Following Arturo's convention for side-effecting builtins (`exit`, `pause`,
`panic`), `cd` returns nothing. There is no attribute and no scoped-block
form: the plain word does one obvious thing.

`path\current` already calls `getCurrentDir()` on every access, so it reflects
the change immediately — no extra state to keep in sync:

```arturo
cd "/tmp"
print path\current      ; /tmp
print execute "pwd"     ; /tmp   <- child processes follow along
```

A non-existing directory raises a proper `Directory not found` system error
(new `Error_DirectoryNotFound`, mirroring `Error_FileNotFound`, `ENOENT`), and
the working directory is left untouched:

```arturo
error? try [ cd "/no/such/dir" ]    ; true
```

---

## A writable `env`

### Before

`env` rebuilt a throwaway `:dictionary` on every call, so this *looked* like it
worked but changed nothing:

```arturo
env\PATH: env\PATH ++ ":/opt/bin"   ; wrote into a temp copy - lost immediately
```

In fact it didn't even get that far: it failed with a type error (see the
`addPath` note below).

### Now

`env` returns one cached `:environment` value whose `get`/`set` magic methods
talk directly to the process environment:

```arturo
env\MY_VAR: "some value"
print env\MY_VAR                    ; some value
print execute "printenv MY_VAR"     ; some value   <- children see it

env\PATH: env\PATH ++ ":/opt/bin"   ; the append idiom just works
```

Reading a variable that isn't set gives `null` rather than an error, and
assigning `null` **removes** the variable — consistent with `null` meaning
"absent" elsewhere in Arturo:

```arturo
null? env\NO_SUCH_VAR   ; true

env\MY_VAR: null
null? env\MY_VAR        ; true
```

Non-string values are stringified on the way out, since that is all an OS
environment can hold:

```arturo
env\COUNT: 42
type env\COUNT          ; :string
```

### Why an object, and why nothing breaks

`:environment` is an `:object` with a Nim-side prototype, registered exactly
the way `:iterator` already is (`helpers/iteratorstate.nim`). The object's own
fields are re-synced from `envPairs()` on every `env` call, so the entire
collection protocol keeps working unchanged:

```arturo
size env                ; works
keys env                ; works
key? env "HOME"         ; works
loop env [k v][ ... ]   ; works
to :dictionary env      ; works
```

The alternative — returning a `:store` — was rejected: `:store` only
implements `get`/`set`, so `keys`, `values`, `size` and `loop` all reject it,
which would have been a real regression for existing `env` code.

The single visible change is `type env`, now `:environment` instead of
`:dictionary`. Code that asks `dictionary? env` should use `to :dictionary env`
(or just keep indexing/iterating, which is unaffected).

---

## Fixed along the way: `addPath` and 0-arity builtins

`config\key: value` silently failed at top level, while the same thing via a
variable worked:

```arturo
config\foo: 1           ; type error
c: config
c\foo: 1                ; fine
```

Cause: in `vm/ast.nim`, `addPath` resolved the *base* of a path differently
depending on which side of `:` it was on. A plain path (`a\b`) called 0-arity
builtins; a path **label** (`a\b:`) always emitted a variable lookup, so `env`
and `config` resolved to the function value itself, and `set` was handed a
`:function`.

Both now use the same base-node logic, so a 0-arity builtin is called in either
position. This is what lets `env\X: ...` work at all, and it fixes
`config\key: value` as a side effect.

---

## Tests

`tests/unittests/lib.system.art` gains `env` and `cd` topics (15 assertions):
read/write round-trips, visibility to child processes, the append idiom, `null`
removal, the full dictionary protocol, directory changes seen by children, and
the error path for a missing directory.

Full suite: **36/38**, unchanged from baseline (the 2 failures are pre-existing
and unrelated).
