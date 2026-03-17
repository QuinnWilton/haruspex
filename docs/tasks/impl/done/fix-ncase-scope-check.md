# Fix: ncase scope/occurs check should inspect closures

**Priority**: medium — can produce unsound meta solutions

## Problem

`occurs_in_neutral?` and `scope_ok_neutral?` for ncase only check the scrutinee head, ignoring branch closures. Free variables and metas inside branch bodies are invisible to the checks, potentially allowing invalid meta solutions.

## Fix

Open each branch closure with fresh variables and recurse, matching the pattern already used for Pi/Sigma/Lambda closures in `occurs_in_closure?` and `scope_ok_closure?`.
