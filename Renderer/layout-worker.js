/* Linen's layout worker: runs ELK.js's layered layout off the page's thread (PRD-2 section 9.2). Started by
   layout.js only when a board has a section with "layout": "layered". Messages: {id, graph} in, {id, result} or
   {id, error} out. ELK ships unmodified in vendor/elk (EPL-2.0, see its README). */
"use strict";
let elk = null;

function loadElk() {
  // elk.bundled.js carries ELK's own worker code, which, when it finds itself in a worker (no `document`), takes
  // over this worker's onmessage instead of exporting its in-thread engine. That code runs when the ELK
  // constructor first requires it, so a stand-in `document` stays until the engine exists; it then runs here.
  self.document = {};
  try {
    importScripts(new URL("vendor/elk/elk.bundled.js", self.location.href).href);
    return new self.ELK();
  } finally {
    delete self.document;
  }
}

self.onmessage = (e) => {
  const { id, graph } = e.data || {};
  try {
    if (!elk) elk = loadElk();
  } catch (err) {
    self.postMessage({ id, error: "ELK did not load: " + (err && err.message) });
    return;
  }
  elk.layout(graph).then(
    (result) => self.postMessage({ id, result }),
    (err) => self.postMessage({ id, error: String((err && err.message) || err) }),
  );
};
