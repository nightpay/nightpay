export type ToastType = 'success' | 'error' | 'info';

export interface Toast {
  id: string;
  message: string;
  type: ToastType;
}

type Listener = (toasts: Toast[]) => void;
let toasts: Toast[] = [];
let listeners: Listener[] = [];

function addToast(message: string, type: ToastType) {
  const id = Math.random().toString(36).substring(2, 9);
  toasts = [...toasts, { id, message, type }];
  emit();
  setTimeout(() => toast.dismiss(id), 5000);
}

export interface ToastAPI {
  (msg: string, type: ToastType): void;
  success: (msg: string) => void;
  error: (msg: string) => void;
  info: (msg: string) => void;
  subscribe: (listener: Listener) => () => void;
  dismiss: (id: string) => void;
}

const toastImpl = (msg: string, type: ToastType) => addToast(msg, type);
toastImpl.success = (msg: string) => addToast(msg, 'success');
toastImpl.error = (msg: string) => addToast(msg, 'error');
toastImpl.info = (msg: string) => addToast(msg, 'info');
toastImpl.subscribe = (listener: Listener) => {
  listeners.push(listener);
  return () => {
    listeners = listeners.filter((l) => l !== listener);
  };
};
toastImpl.dismiss = (id: string) => {
  toasts = toasts.filter((t) => t.id !== id);
  emit();
};

export const toast: ToastAPI = toastImpl;

function emit() {
  listeners.forEach((listener) => listener(toasts));
}