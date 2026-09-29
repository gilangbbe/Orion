# Draft issue for apple/coreai-models (not filed)

**Title:** Guided generation ignores `@Generable` property order (`x-order`): fields are generated in dictionary order

**Revision:** main @ `e7b24da85ea64a77d26324d7ce9607de9b955f57`, macOS 27.0, Xcode 27.

**What happens**
- `CoreAIExecutor.respondConstrained` JSON-encodes `request.schema` and hands the string to xgrammar.
- FoundationModels encodes a `GenerationSchema`'s `properties` as a dictionary, with no defined
  order. The declaration order is carried separately, in `"x-order"`. For example:

  ```json
  {"properties":{"met":{...},"evidenceQuote":{...},"confidence":{...},"reasoning":{...}},
   "x-order":["evidenceQuote","reasoning","met","confidence"], ...}
  ```

- xgrammar's `SchemaParser::ParseObject` iterates `properties` in insertion order. Its picojson
  build uses `PICOJSON_USE_ORDERED_OBJECT`, and it never reads `x-order`.
- So the constrained output generates fields in dictionary order, which can change between
  processes, instead of in declaration order.

**Why it matters.** Declaration order is how FoundationModels users put a reasoning field before
the decision it informs, the documented "generate the rationale first" pattern. On Core AI the
decision can be generated first. Observed live: a snapshot showed `met` and `confidence` already
generated while `reasoning` was still partial.

**Expected.** Reorder `properties` by `x-order`, recursively for nested objects, before passing
the schema to xgrammar. This matches what the system model does.

**Workaround used.** Split the schema into two guided turns in one session: the analysis first,
then the decision.
