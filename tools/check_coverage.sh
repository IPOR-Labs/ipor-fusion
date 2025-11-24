#!/bin/bash

# Użycie: ./tools/check_coverage.sh <sciezka_do_kontraktu> <wzorzec_plikow_testowych>
# Przykład: ./tools/check_coverage.sh contracts/MyVault.sol "test/MyVault.t.sol"

TARGET_FILE=$1
TEST_PATTERN=$2

# Kolory do outputu
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [ -z "$TARGET_FILE" ] || [ -z "$TEST_PATTERN" ]; then
    echo "Użycie: $0 <sciezka_do_kontraktu> <wzorzec_plikow_testowych>"
    exit 1
fi

echo "Sprawdzanie pokrycia dla pliku: $TARGET_FILE"
echo "Używane testy: $TEST_PATTERN"

# 1. Uruchomienie forge coverage z filtrowaniem testów
# Używamy --match-path aby ograniczyć wykonywane testy tylko do tych wskazanych
# Zapisujemy wyjście do zmiennej, zachowując formatowanie tabeli
OUTPUT=$(forge coverage --match-path "$TEST_PATTERN")
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo -e "${RED}Błąd podczas uruchamiania forge coverage${NC}"
    echo "$OUTPUT"
    exit $EXIT_CODE
fi

# 2. Wyszukanie wiersza z wynikiem dla naszego pliku
# Szukamy nazwy pliku otoczonej spacjami (w tabeli)
ROW=$(echo "$OUTPUT" | grep " $TARGET_FILE ")

if [ -z "$ROW" ]; then
    echo -e "${RED}Nie znaleziono pliku $TARGET_FILE w raporcie pokrycia.${NC}"
    echo "Upewnij się, że uruchomione testy faktycznie używają tego pliku."
    echo "Dostępne pliki w raporcie:"
    echo "$OUTPUT" | grep "|" | grep -v "File" | grep -v "\-\-\-"
    exit 1
fi

# 3. Wyświetlenie nagłówka i wyniku
echo ""
echo "Raport dla pliku:"
echo "$OUTPUT" | grep "| File"
echo "$OUTPUT" | grep "|---"
echo "$ROW"
echo "$OUTPUT" | grep "|---"
echo ""

# 4. Walidacja pokrycia (Lines) - kolumna 3
# Format: | File | % Lines | ...
# Wyciągamy wartość procentową (np. "100.00%")
LINE_COV_RAW=$(echo "$ROW" | awk -F '|' '{print $3}')
# Usuwamy znaki procenta i białe znaki, zostawiamy samą liczbę (np. 100.00)
LINE_COV=$(echo "$LINE_COV_RAW" | sed -E 's/[^0-9.]*([0-9.]+)%.*/\1/')

# Sprawdzenie czy pokrycie wynosi 100.00
# Używamy porównania łańcuchowego dla precyzji
if [[ "$LINE_COV" == "100.00" ]]; then
    echo -e "${GREEN}✅ Pokrycie linii wynosi 100%${NC}"
    exit 0
else
    echo -e "${RED}❌ Pokrycie linii wynosi $LINE_COV% (Wymagane: 100.00%)${NC}"
    exit 1
fi

