#!/usr/bin/env node
"use strict";

// Compat shim: @orca-sec/ryk also registers `orca` as a bin.
// Delegates to the same installer/launcher as ryk.js.
require("./ryk.js");
