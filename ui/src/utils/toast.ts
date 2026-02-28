export type ToastType = 'success' | 'error' | 'info';

export interface Toast {
  id: string;
  message: string;
  type: ToastType;
}

type Listener = (toasts: Toast[]) => void;
let toasts: Toast[] = [];
let listeners: Listener[] = [];

export const toast = {
  success: (msg: string) => addToast(msg, 'success'),
  error: (msg: string) => addToast(msg, 'error'),
  info: (msg: string) => addToast(msg, 'info'),
  subscribe: (listener: Listener) => {
    listeners.push(listener);
    return () => {
      listeners = listeners.filter((l) => l !== listener);
    };
  },
  dismiss: (id: string) => {
    toasts = toasts.filter((t) => t.id !== id);
    emit();
  }
};

function addToast(message: string, type: ToastType) {
  const id = Math.random().toString(36).substring(2, 9);
  toasts = [...toasts, { id, message, type }];
  emit();
  setTimeout(() => toast.dismiss(id), 5000);
}

function emit() {
  listeners.forEach((listener) => listener(toasts));
}