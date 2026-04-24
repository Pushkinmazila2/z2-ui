#!/usr/bin/env python3
"""
Change password for Zapret Control Panel
"""

import os
import sys
import hashlib
import getpass

AUTH_FILE = os.path.join(os.path.dirname(__file__), '.htpasswd')

def change_password(username):
    """Change password for user"""
    password = getpass.getpass(f"Новый пароль для {username}: ")
    password_confirm = getpass.getpass("Подтвердите пароль: ")
    
    if password != password_confirm:
        print("Пароли не совпадают!")
        return False
    
    if len(password) < 4:
        print("Пароль слишком короткий (минимум 4 символа)")
        return False
    
    password_hash = hashlib.sha256(password.encode()).hexdigest()
    
    # Read existing users
    users = {}
    if os.path.exists(AUTH_FILE):
        with open(AUTH_FILE, 'r') as f:
            for line in f:
                if ':' in line:
                    user, hash_val = line.strip().split(':', 1)
                    users[user] = hash_val
    
    # Update password
    users[username] = password_hash
    
    # Write back
    with open(AUTH_FILE, 'w') as f:
        for user, hash_val in users.items():
            f.write(f'{user}:{hash_val}\n')
    
    print(f"Пароль для {username} успешно изменен")
    return True

def main():
    if len(sys.argv) > 1:
        username = sys.argv[1]
    else:
        username = input("Имя пользователя [admin]: ").strip() or "admin"
    
    change_password(username)

if __name__ == '__main__':
    main()
```