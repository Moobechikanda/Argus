export function displayFileRef(fileRef: string | null | undefined): string {
  if (!fileRef) return '—';
  if (/^[a-z][a-z0-9+.-]*:/i.test(fileRef) || fileRef.includes('?') || fileRef.includes('#')) {
    return 'invalid reference';
  }
  return fileRef.split('/').pop() || 'invalid reference';
}
