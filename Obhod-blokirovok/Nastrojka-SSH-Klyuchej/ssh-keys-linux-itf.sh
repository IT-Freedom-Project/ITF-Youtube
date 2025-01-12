#!/bin/bash

# Убедимся, что скрипт выполняется не от root
if [ "$EUID" -eq 0 ]; then
  echo "Пожалуйста, запустите этот скрипт не от имени root."
  exit 1
fi

# Проверяем, установлен ли ssh
if ! command -v ssh >/dev/null 2>&1; then
  echo "Команда 'ssh' не найдена. Попробуем установить openssh-client..."
  sudo apt-get update && sudo apt-get install -y openssh-client
  if [ $? -ne 0 ]; then
    echo "Не удалось установить openssh-client. Завершение."
    exit 1
  fi
fi

# Упрощенный скрипт для создания и управления SSH-ключами
# (ключ всегда передается на сервер, без проверок,
#  а при настройке входа по паролю параметр PasswordAuthentication
#  полностью удаляется и добавляется нужное значение)

# Запрашиваем тип ключа
echo "Выберите тип ключа:"
echo "1) RSA"
echo "2) ED25519 (по умолчанию)"
read -p "Ваш выбор (1-2): " KEY_TYPE_CHOICE
case "$KEY_TYPE_CHOICE" in
  1)
    KEY_TYPE="rsa"
    ;;
  2|"")
    KEY_TYPE="ed25519"
    ;;
  *)
    echo "Некорректный выбор. Завершение."
    exit 1
    ;;
esac

if [[ "$KEY_TYPE" != "rsa" && "$KEY_TYPE" != "ed25519" ]]; then
  echo "Некорректный тип ключа. Завершение."
  exit 1
fi

# Запрашиваем имя ключа
read -p "Введите имя файла для ключа (по умолчанию ~/.ssh/id_${KEY_TYPE}): " KEY_NAME
KEY_NAME=${KEY_NAME:-~/.ssh/id_${KEY_TYPE}}

# Убедимся, что ключ создается в папке .ssh
if [[ "$KEY_NAME" != /* && "$KEY_NAME" != ~/.ssh/* ]]; then
  KEY_NAME=~/.ssh/$KEY_NAME
fi

# Проверяем, существует ли уже ключ
if [ -f "$KEY_NAME" ]; then
  echo "Ключ с именем $KEY_NAME ($KEY_TYPE) уже существует."
  echo "Выберите действие:"
  echo "1) Ввести другое имя"
  echo "2) Отменить создание ключа"
  echo "3) Перезаписать существующий ключ"
  echo "4) Изменить пароль для существующего ключа"
  echo "5) Изменить комментарий для существующего ключа"
  echo "6) Передать ключ на сервер (всегда)"
  echo "7) Добавить ключ в ssh-agent"
  read -p "Ваш выбор (1-7): " CHOICE

  case "$CHOICE" in
    1)
      exec "$0"  # Перезапустить скрипт заново
      ;;
    2)
      echo "Отмена создания ключа."
      exit 1
      ;;
    3)
      echo "Ключ будет перезаписан (при генерации)."
      ;;
    4)
      echo "Изменение пароля для существующего ключа."
      while true; do
        read -s -p "Введите новый пароль для ключа (Enter для пустого пароля): " NEW_PASSPHRASE
        echo
        read -s -p "Подтвердите новый пароль (Enter для пустого пароля): " CONFIRM_PASSPHRASE
        echo
        if [[ "$NEW_PASSPHRASE" == "$CONFIRM_PASSPHRASE" ]]; then
          ssh-keygen -p -f "$KEY_NAME" -N "$NEW_PASSPHRASE"
          if [ $? -eq 0 ]; then
            echo "Пароль для ключа успешно изменен."
            ssh-add "$KEY_NAME"
            echo "Ключ добавлен в ssh-agent."
          else
            echo "Ошибка при изменении пароля ключа."
          fi
          exit 0
        else
          echo "Пароли не совпадают. Попробуйте снова."
        fi
      done
      ;;
    5)
      echo "Изменение комментария для существующего ключа."
      read -p "Введите новый комментарий для ключа: " NEW_COMMENT
      if [[ -n "$NEW_COMMENT" ]]; then
        ssh-keygen -c -f "$KEY_NAME" -C "$NEW_COMMENT"
        if [ $? -eq 0 ]; then
          echo "Комментарий для ключа успешно изменен."
          ssh-add "$KEY_NAME"
          echo "Ключ добавлен в ssh-agent."
        else
          echo "Ошибка при изменении комментария ключа."
        fi
      else
        echo "Комментарий не изменен."
      fi
      exit 0
      ;;
    6)
      # -- Всегда передаём ключ, без проверок --
      echo "Передача ключа на сервер."
      read -p "Введите логин для сервера: " REMOTE_USER
      read -p "Введите IP-адрес сервера: " REMOTE_IP
      read -p "Введите порт сервера (по умолчанию 22): " REMOTE_PORT
      REMOTE_PORT=${REMOTE_PORT:-22}

      echo "Передача ключа на сервер (ssh-copy-id)..."
      ssh-copy-id -i "$KEY_NAME" -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}"
      if [ $? -eq 0 ]; then
        echo "Ключ успешно передан на сервер."
      else
        echo "Не удалось передать ключ через ssh-copy-id."
        echo "Пробуем альтернативный способ..."
        cat "${KEY_NAME}.pub" | ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" \
          "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        if [ $? -eq 0 ]; then
          echo "Ключ успешно передан на сервер альтернативным способом."
        else
          echo "Ошибка передачи ключа на сервер даже альтернативным способом. Проверьте данные подключения."
          exit 1
        fi
      fi

      # Предлагаем управлять настройками входа по паролю
      read -p "Хотите ли вы управлять настройками входа по паролю на сервере? [y/N]: " CHANGE_PASSAUTH
      CHANGE_PASSAUTH=${CHANGE_PASSAUTH,,}
      if [[ "$CHANGE_PASSAUTH" == "y" ]]; then
        # Начинаем цикл, пока не будет правильного sudo-пароля
        while true; do
          echo "Введите пароль для sudo на сервере (требуется для изменения /etc/ssh/sshd_config):"
          read -s SUDO_PASS

          # Проверяем, верный ли пароль (sudo -v проверяет, может ли sudo аутентифицироваться)
          ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" \
            "echo \"$SUDO_PASS\" | sudo -S -v" 2>/dev/null

          if [ $? -eq 0 ]; then
            echo "Пароль принят."
            break
          else
            echo "Неверный пароль sudo, попробуйте ещё раз."
          fi
        done

        # Узнаём текущее «фактическое» состояние PasswordAuthentication
        CURRENT_PA=$(ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" \
          "echo \"$SUDO_PASS\" | sudo -S sshd -T | grep '^passwordauthentication'")

        if echo "$CURRENT_PA" | grep -iq 'yes'; then
          echo "Сейчас вход по паролю ВКЛЮЧЕН."
        else
          echo "Сейчас вход по паролю ОТКЛЮЧЕН."
        fi

        echo "Хотите включить (y) или отключить (n) вход по паролю? [y/n]:"
        read -p "Ваш выбор: " TOGGLE
        TOGGLE=${TOGGLE,,}

        if [[ "$TOGGLE" == "y" ]]; then
          # Включаем вход по паролю
          ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" "
            echo \"$SUDO_PASS\" | sudo -S sed -i '/^[#[:space:]]*PasswordAuthentication/d' /etc/ssh/sshd_config
            echo \"$SUDO_PASS\" | sudo -S bash -c 'echo \"PasswordAuthentication yes\" >> /etc/ssh/sshd_config'
            if command -v systemctl >/dev/null 2>&1; then
              echo \"$SUDO_PASS\" | sudo -S systemctl restart ssh || sudo -S systemctl restart sshd
            else
              echo \"$SUDO_PASS\" | sudo -S service ssh restart || sudo -S service sshd restart
            fi
          "
          echo "Вход по паролю включен."
        elif [[ "$TOGGLE" == "n" ]]; then
          # Отключаем вход по паролю
          ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" "
            echo \"$SUDO_PASS\" | sudo -S sed -i '/^[#[:space:]]*PasswordAuthentication/d' /etc/ssh/sshd_config
            echo \"$SUDO_PASS\" | sudo -S bash -c 'echo \"PasswordAuthentication no\" >> /etc/ssh/sshd_config'
            if command -v systemctl >/dev/null 2>&1; then
              echo \"$SUDO_PASS\" | sudo -S systemctl restart ssh || sudo -S systemctl restart sshd
            else
              echo \"$SUDO_PASS\" | sudo -S service ssh restart || sudo -S service sshd restart
            fi
          "
          echo "Вход по паролю отключен."
        else
          echo "Ничего не меняем."
        fi
      fi
      exit 0
      ;;
    7)
      echo "Добавление ключа в ssh-agent."
      ssh-add "$KEY_NAME"
      if [ $? -eq 0 ]; then
        echo "Ключ успешно добавлен в ssh-agent."
      else
        echo "Ошибка при добавлении ключа в ssh-agent."
      fi
      exit 0
      ;;
    *)
      echo "Некорректный выбор. Завершение."
      exit 1
      ;;
  esac
fi

# Запрашиваем комментарий для нового ключа
read -p "Введите описание для ключа (например, email или описание): " COMMENT
COMMENT=${COMMENT:-"No Comment"}

# Предлагаем ввести пароль для ключа (при пустом вводе не будет пароля)
echo "Введите пароль для ключа (Enter, чтобы оставить без пароля): "
read -s PASSPHRASE
echo
echo "Подтвердите пароль (Enter для пустого пароля): "
read -s CONFIRM_PASSPHRASE
echo
if [[ "$PASSPHRASE" != "$CONFIRM_PASSPHRASE" ]]; then
  echo "Пароли не совпадают. Попробуйте снова."
  exit 1
fi

# Генерация ключа
ssh-keygen -t "$KEY_TYPE" -C "$COMMENT" -f "$KEY_NAME" -N "$PASSPHRASE"

# Проверяем успешность создания ключа
if [ $? -eq 0 ]; then
  echo "SSH-ключ успешно создан:"
  echo "- Приватный ключ: $KEY_NAME"
  echo "- Публичный ключ: ${KEY_NAME}.pub"
  ssh-add "$KEY_NAME"
  echo "Ключ добавлен в ssh-agent."
else
  echo "Ошибка при создании SSH-ключа."
  exit 1
fi

# Всегда предлагаем передать ключ на сервер
read -p "Хотите ли вы передать ключ на сервер? [y/N]: " TRANSFER_KEY
TRANSFER_KEY=${TRANSFER_KEY,,}
if [[ "$TRANSFER_KEY" == "y" ]]; then
  read -p "Введите логин для сервера: " REMOTE_USER
  read -p "Введите IP-адрес сервера: " REMOTE_IP
  read -p "Введите порт сервера (по умолчанию 22): " REMOTE_PORT
  REMOTE_PORT=${REMOTE_PORT:-22}

  echo "Передача ключа на сервер (ssh-copy-id)..."
  ssh-copy-id -i "$KEY_NAME" -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}"
  if [ $? -eq 0 ]; then
    echo "Ключ успешно передан на сервер."
  else
    echo "Не удалось передать ключ через ssh-copy-id."
    echo "Пробуем альтернативный способ..."
    cat "${KEY_NAME}.pub" | ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    if [ $? -eq 0 ]; then
      echo "Ключ успешно передан на сервер альтернативным способом."
    else
      echo "Ошибка передачи ключа на сервер даже альтернативным способом. Проверьте данные подключения."
      exit 1
    fi
  fi

  # (Далее логика управления PasswordAuthentication, аналогично пункту 6)
  read -p "Хотите ли вы управлять настройками входа по паролю на сервере? [y/N]: " CHANGE_PASSAUTH
  CHANGE_PASSAUTH=${CHANGE_PASSAUTH,,}
  if [[ "$CHANGE_PASSAUTH" == "y" ]]; then
    while true; do
      echo "Введите пароль для sudo на сервере (требуется для изменения /etc/ssh/sshd_config):"
      read -s SUDO_PASS

      # Проверяем пароль
      ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" \
        "echo \"$SUDO_PASS\" | sudo -S -v" 2>/dev/null

      if [ $? -eq 0 ]; then
        echo "Пароль принят."
        break
      else
        echo "Неверный пароль sudo, попробуйте ещё раз."
      fi
    done

    CURRENT_PA=$(ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" \
      "echo \"$SUDO_PASS\" | sudo -S sshd -T | grep '^passwordauthentication'")

    if echo "$CURRENT_PA" | grep -iq 'yes'; then
      echo "Сейчас вход по паролю ВКЛЮЧЕН."
    else
      echo "Сейчас вход по паролю ОТКЛЮЧЕН."
    fi

    echo "Хотите включить (y) или отключить (n) вход по паролю? [y/n]:"
    read -p "Ваш выбор: " TOGGLE
    TOGGLE=${TOGGLE,,}

    if [[ "$TOGGLE" == "y" ]]; then
      ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" "
        echo \"$SUDO_PASS\" | sudo -S sed -i '/^[#[:space:]]*PasswordAuthentication/d' /etc/ssh/sshd_config
        echo \"$SUDO_PASS\" | sudo -S bash -c 'echo \"PasswordAuthentication yes\" >> /etc/ssh/sshd_config'
        if command -v systemctl >/dev/null 2>&1; then
          echo \"$SUDO_PASS\" | sudo -S systemctl restart ssh || sudo -S systemctl restart sshd
        else
          echo \"$SUDO_PASS\" | sudo -S service ssh restart || sudo -S service sshd restart
        fi
      "
      echo "Вход по паролю включен."
    elif [[ "$TOGGLE" == "n" ]]; then
      ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_IP}" "
        echo \"$SUDO_PASS\" | sudo -S sed -i '/^[#[:space:]]*PasswordAuthentication/d' /etc/ssh/sshd_config
        echo \"$SUDO_PASS\" | sudo -S bash -c 'echo \"PasswordAuthentication no\" >> /etc/ssh/sshd_config'
        if command -v systemctl >/dev/null 2>&1; then
          echo \"$SUDO_PASS\" | sudo -S systemctl restart ssh || sudo -S systemctl restart sshd
        else
          echo \"$SUDO_PASS\" | sudo -S service ssh restart || sudo -S service sshd restart
        fi
      "
      echo "Вход по паролю отключен."
    else
      echo "Ничего не меняем."
    fi
  fi
fi

# Выводим публичный ключ
echo "Ваш публичный ключ:"
cat "${KEY_NAME}.pub"

echo "Готово! Используйте публичный ключ для авторизации на серверах."
