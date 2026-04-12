export default function PageLoader() {
  return (
    <div className="flex h-[50vh] w-full items-center justify-center">
      <div className="flex flex-col items-center gap-4">
        <div className="h-8 w-8 animate-spin rounded-full border-2 border-void-600 border-t-neon-cyan"></div>
        <p className="text-xs font-semibold uppercase tracking-widest text-neon-cyan/80 animate-pulse">Loading View</p>
      </div>
    </div>
  );
}
