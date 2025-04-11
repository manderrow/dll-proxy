# dll-proxy

Trivially embeddable library that adds exports for proxying to another DLL. Very useful for injection. You can "replace" a target DLL by putting your own DLL in a higher priority position on the search path and proxy usages of that DLL's functions to the real thing.

