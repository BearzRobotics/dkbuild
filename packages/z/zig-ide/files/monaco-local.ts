// Added by the dkbuild recipe (see package.toml): @monaco-editor/react loads Monaco from the jsdelivr CDN at run time by default;
// this makes it use the monaco-editor package bundled by Vite instead, so the editor works offline.
import * as monaco from 'monaco-editor';
import editorWorker from 'monaco-editor/esm/vs/editor/editor.worker?worker';
import { loader } from '@monaco-editor/react';

(self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
  getWorker: () => new editorWorker(),
};
loader.config({ monaco });
