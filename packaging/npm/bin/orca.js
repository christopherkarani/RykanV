#!/usr/bin/env node
"use strict";

// Compat shim: @orca-sec/ryk also registers `orca` as a bin.
// Delegates to the same installer/launcher as ryk.js.
// Integrity and checksum verification are handled by the shared launcher.
require("./ryk.js");
