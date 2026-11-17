package securitykey

import "testing"

func TestNixLibraryLoadsWithoutOpeningAKey(t *testing.T) {
	if err := CheckSupport(); err != nil {
		t.Fatal(err)
	}
}
