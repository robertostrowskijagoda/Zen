// Package mldsa is ML-DSA (FIPS 204), as Go 1.26 implements it in
// crypto/internal/fips140/mldsa. Go 1.26 has no public crypto/mldsa yet, so
// the files are copied here unchanged except for the imports: the public
// crypto/sha3, crypto/subtle, crypto/rand and encoding/binary stand in for
// the module-internal ones, and the FIPS 140-3 self-tests and service
// indicator calls are left out. The licence is Go's (BSD-3-Clause, in
// LICENSES-GO.txt). Replace the package with crypto/mldsa once the bridge
// moves to a Go release that has it.
//
// Zen uses ML-DSA-65 only (internal/zensig).
package mldsa
