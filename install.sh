#!/bin/bash

# Функция для установки конфига по умолчанию
default_install() {
  echo "Запуск install_easy.sh..."
  if ! sudo "$HOME/Library/zapret/install_easy.sh"; then
    echo "Ошибка: не удалось запустить install_easy.sh."
  fi
}

clear

# Собираем список файлов
configs=("$HOME/zapret-configs/configs"/*)
if [ ${#configs[@]} -eq 0 ]; then
  echo "Ошибка: в папке $HOME/zapret-configs/configs/ нет файлов."
  exit 1
fi

while true; do
  clear

  echo "Выберите конфиг для установки:"
  for i in "${!configs[@]}"; do
    echo "$((i+1)). $(basename "${configs[$i]}")"
  done

  read -rp "Введите номер конфига: " choice

  # Проверка на корректность выбора
  # regex на число && число больше или равно 1 && число меньше или равно количеству элементов в массиве
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#configs[@]}" ]; then
    selected_config="${configs[$((choice-1))]}"
    echo "Установка конфига $(basename "$selected_config")..."
    if ! cp "$selected_config" "$HOME/Library/zapret/config"; then
      echo "Ошибка: не удалось скопировать конфиг."
      exit 1
    fi
    default_install
    break
  else
    echo "Неверный выбор. Попробуйте снова."
    echo
  fi
done

echo "Установка завершена успешно!"
