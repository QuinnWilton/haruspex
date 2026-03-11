# Values and NbE

## Purpose

Defines the value domain for normalization-by-evaluation and implements `eval` (term to value), `quote` (value to term, type-directed with eta-expansion), and `conv` (value equality via unification). See [[../decisions/d03-nbe-conversion]], [[../decisions/d15-eta-expansion]].

## Dependencies

- `Haruspex.Core` — term representation
- `pentiment` — spans (excluded from NbE)

## Key types

```elixir
# Environment: list of values, indexed by de Bruijn level
@type env :: [value()]
@type lvl :: non_neg_integer()    # de Bruijn level (counts from bottom)

# Values
@type value ::
  {:vlam, mult(), env(), Core.term()}                # closure
  | {:vpi, mult(), value(), env(), Core.term()}      # Pi type closure
  | {:vsigma, value(), env(), Core.term()}           # Sigma type closure
  | {:vpair, value(), value()}                       # pair value
  | {:vtype, Core.level()}                           # universe value
  | {:vlit, Core.literal()}                          # literal value
  | {:vbuiltin, atom()}                              # builtin value
  | {:vneutral, value(), neutral()}                  # stuck computation (type-tagged for eta)

# Neutral terms (stuck computations)
@type neutral ::
  {:nvar, lvl()}                                     # free variable (de Bruijn level)
  | {:napp, neutral(), value()}                      # stuck application
  | {:nfst, neutral()}                               # stuck first projection
  | {:nsnd, neutral()}                               # stuck second projection
  | {:nmeta, Core.meta_id()}                         # unsolved metavariable
```

## Public API

```elixir
# Evaluation
@spec eval(env(), Core.term()) :: value()

# Type-directed readback with eta-expansion
@spec quote(lvl(), value(), value()) :: Core.term()
  # quote(depth, type, value) -> normal-form term

# Convenience: quote without type (no eta, for debugging)
@spec quote_untyped(lvl(), value()) :: Core.term()

# Application (used by eval and unification)
@spec vapp(value(), value()) :: value()

# Projections
@spec vfst(value()) :: value()
@spec vsnd(value()) :: value()

# Create a fresh variable at a given level
@spec fresh_var(lvl(), value()) :: value()
  # fresh_var(level, type) -> VNeutral(type, NVar(level))
```

## Evaluation algorithm

```
eval(env, Var(ix))          = env[ix]  (index into environment from the right)
eval(env, Lam(m, body))     = VLam(m, env, body)
eval(env, App(f, a))        = vapp(eval(env, f), eval(env, a))
eval(env, Pi(m, dom, cod))  = VPi(m, eval(env, dom), env, cod)
eval(env, Sigma(a, b))      = VSigma(eval(env, a), env, b)
eval(env, Pair(a, b))       = VPair(eval(env, a), eval(env, b))
eval(env, Fst(e))           = vfst(eval(env, e))
eval(env, Snd(e))           = vsnd(eval(env, e))
eval(env, Let(def, body))   = eval([eval(env, def) | env], body)
eval(env, Type(l))          = VType(l)
eval(env, Lit(v))           = VLit(v)
eval(env, Builtin(n))       = VBuiltin(n)
eval(env, Meta(id))         = look up meta; if solved, eval solution; else VNeutral(_, NMeta(id))
eval(env, InsertedMeta(id, mask)) = apply meta to masked env variables

vapp(VLam(_, env, body), arg)  = eval([arg | env], body)
vapp(VNeutral(VPi(_, _, env, cod), ne), arg) = VNeutral(eval([arg | env], cod), NApp(ne, arg))
vapp(VBuiltin(op), arg)        = delta-reduce builtins

vfst(VPair(a, _))              = a
vfst(VNeutral(VSigma(a, _, _), ne)) = VNeutral(a, NFst(ne))

vsnd(VPair(_, b))              = b
vsnd(VNeutral(VSigma(_, env, b), ne)) = VNeutral(eval([vfst(ne_val) | env], b), NSnd(ne))
```

## Readback algorithm (type-directed)

```
quote(l, VPi(m, dom, env, cod), val):
  # eta-expand if neutral, recurse if lambda
  case val:
    VLam(_, env2, body):
      arg = fresh_var(l, dom)
      body_val = eval([arg | env2], body)
      cod_val = eval([arg | env], cod)
      Lam(m, quote(l+1, cod_val, body_val))
    VNeutral(_, ne):
      # eta-expansion
      arg = fresh_var(l, dom)
      body_val = vapp(val, arg)
      cod_val = eval([arg | env], cod)
      Lam(m, quote(l+1, cod_val, body_val))

quote(l, VSigma(a, env, b), val):
  # eta-expand if neutral
  fst_val = vfst(val)
  snd_val = vsnd(val)
  b_val = eval([fst_val | env], b)
  Pair(quote(l, a, fst_val), quote(l, b_val, snd_val))

quote(l, VType(_), VPi(m, dom, env, cod)):
  arg = fresh_var(l, dom)
  cod_val = eval([arg | env], cod)
  Pi(m, quote(l, VType(...), dom), quote(l+1, VType(...), cod_val))

quote(l, _, VNeutral(_, ne)):
  quote_neutral(l, ne)

quote(l, _, VLit(v)):    Lit(v)
quote(l, _, VType(lv)):  Type(lv)
# etc.

quote_neutral(l, NVar(lvl)):     Var(l - lvl - 1)  # level to index conversion
quote_neutral(l, NApp(ne, arg)): App(quote_neutral(l, ne), quote_untyped(l, arg))
# etc.
```

## Implementation notes

- Environment is a list with most recent binding at the head (index 0 = head)
- `VNeutral` is tagged with the value's type so readback can eta-expand
- De Bruijn level to index conversion: `index = current_depth - level - 1`
- Meta lookup during eval: consult `Haruspex.Unify.MetaState` for solved metas
- Builtins: delta-reduction for arithmetic (`+`, `-`, `*`, `/`), comparison, boolean ops

## Testing strategy

- **Unit tests**: eval/quote for each term form individually
- **Property tests**:
  - NbE stability: for well-typed closed terms, `quote(eval(t))` is equivalent to `t` (up to normal form)
  - Eta: `quote(eval(f), Pi(A, B)) = Lam(App(f, Var(0)))` when f is a neutral
  - Level-to-index conversion: `l - (l - lvl - 1) - 1 == lvl` (round-trip)
- **Integration**: NbE correctly normalizes `(fn x -> x + 1)(2)` to `3`
