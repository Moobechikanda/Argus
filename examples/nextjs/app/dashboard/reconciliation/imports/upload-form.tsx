'use client';

import { useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { createImportJob } from '@/lib/actions/reconciliation';

type Source = { id: string; name: string };

export function ImportUploadForm({ companyId, sources }: { companyId: string; sources: Source[] }) {
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(formData: FormData) {
    setBusy(true);
    setMessage('');
    try {
      const dataSourceId = String(formData.get('data_source_id') ?? '');
      const file = formData.get('file');
      if (!(file instanceof File) || file.size < 1 || file.size > 50 * 1024 * 1024) {
        setMessage('Choose a file between 1 byte and 50 MiB.');
        return;
      }
      const extension = file.name.split('.').pop()?.toLowerCase();
      if (!extension || !['csv', 'json', 'jsonl'].includes(extension)) {
        setMessage('Only CSV, JSON, and JSONL files are accepted.');
        return;
      }
      if (!sources.some((source) => source.id === dataSourceId)) {
        setMessage('Choose a valid data source.');
        return;
      }
      const fileRef = `${companyId}/${dataSourceId}/${crypto.randomUUID()}.${extension}`;
      const contentTypes: Record<string, string> = {
        csv: 'text/csv', json: 'application/json', jsonl: 'application/x-ndjson',
      };
      const supabase = createClient();
      const { error: uploadError } = await supabase.storage.from('reconciliation-imports')
        .upload(fileRef, file, { contentType: contentTypes[extension], upsert: false });
      if (uploadError) {
        setMessage(`Upload failed: ${uploadError.message}`);
        return;
      }
      const result = await createImportJob({ dataSourceId, fileRef });
      if (result.error) {
        setMessage(`Job creation failed: ${result.error}. The uploaded private object may need administrative cleanup.`);
        return;
      }
      window.location.reload();
    } finally {
      setBusy(false);
    }
  }

  return (
    <form action={submit} className="card" style={{ marginBottom: 24 }}>
      <h2 style={{ marginBottom: 12 }}>Upload an import file</h2>
      <label htmlFor="data_source_id">Data source</label>
      <select id="data_source_id" name="data_source_id" required defaultValue="">
        <option value="" disabled>Select a source</option>
        {sources.map((source) => <option key={source.id} value={source.id}>{source.name}</option>)}
      </select>
      <label htmlFor="file" style={{ display: 'block', marginTop: 12 }}>CSV, JSON, or JSONL (maximum 50 MiB)</label>
      <input id="file" name="file" type="file" accept=".csv,.json,.jsonl" required />
      <button className="btn" type="submit" disabled={busy || sources.length === 0} style={{ marginTop: 12 }}>
        {busy ? 'Uploading…' : 'Upload and queue import'}
      </button>
      {message && <p role="status" style={{ marginTop: 12 }}>{message}</p>}
      {sources.length === 0 && <p>No active data sources are available.</p>}
    </form>
  );
}
