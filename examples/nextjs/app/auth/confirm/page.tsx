import Link from 'next/link';

export default async function ConfirmPage({
  searchParams,
}: {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>;
}) {
  const params = await searchParams;
  const requestedNext = Array.isArray(params.next) ? params.next[0] : params.next;
  const next = requestedNext?.startsWith('/') && !requestedNext.startsWith('//')
    ? requestedNext
    : '/dashboard';
  const error = params.error;

  return (
    <div className="container" style={{ maxWidth: 420, marginTop: 40 }}>
      <h1>Confirm Email</h1>
      <div className="card">
        {error ? (
          <>
            <p className="error">Confirmation failed. Please try again.</p>
            <p>
              Already have an account? <Link href="/auth/login">Sign in</Link>
            </p>
          </>
        ) : (
          <>
            <p className="success">Email confirmed! You are now signed in.</p>
            <p>
              <Link href={next} className="btn">
                Continue to dashboard
              </Link>
            </p>
          </>
        )}
      </div>
    </div>
  );
}
