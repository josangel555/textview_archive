// Empty public header — SwiftPM requires publicHeadersPath to exist
// for C targets. The wrapper exposes no API to importers; consumers
// load it at runtime via dlopen and resolve symbols by name (see
// Sources/ViewerCore/Highlight/GrammarLoader.swift).
