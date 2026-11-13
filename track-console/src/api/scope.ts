import { createContext, useContext } from 'react';
import { api } from './client';

export const AppScope = createContext({ api, appPackage: undefined as string | undefined });

export function useAppScope() {
  return useContext(AppScope);
}
