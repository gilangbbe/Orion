# SCIP protobuf

`scip.proto` is vendored from https://github.com/sourcegraph/scip (main).

The Swift bindings are committed at
`../Sources/OrionCodeIntel/Scip/ScipProto.generated.swift` so no `protoc` is needed at
build time. To regenerate (needs `protoc` + `protoc-gen-swift` matching the pinned
`swift-protobuf`):

```sh
protoc --swift_out=../Sources/OrionCodeIntel/Scip \
       --swift_opt=Visibility=Public \
       -I . scip.proto
mv ../Sources/OrionCodeIntel/Scip/scip.pb.swift \
   ../Sources/OrionCodeIntel/Scip/ScipProto.generated.swift
```
